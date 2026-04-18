import AVFoundation
import Speech

/// Wraps `SFSpeechRecognizer` and `AVAudioEngine` for hold-to-record voice input.
///
/// **Threading contract:**
/// All public methods must be called from the main thread.
/// All callbacks (`onPartialResult`, `onFinalResult`, `onError`, `onAudioLevel`,
/// `onLocaleUnavailable`) are invoked on the main thread.
///
/// Note: the two synchronous `onError` paths inside `startRecording()` (recognizer
/// guard and audio-engine start failure) are exceptions that rely on callers always
/// being on the main thread rather than dispatching explicitly. `isRestartingRecording`
/// in `AppDelegate` prevents re-entrant calls through those paths.
final class SpeechEngine {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Pool of ready recognizers keyed by locale identifier.
    // All languages in the cycle are kept warm simultaneously so switching
    // between them is a zero-cost pointer swap with no cold-start latency.
    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private var activeLocaleCode: String

    var locale: Locale {
        get { Locale(identifier: activeLocaleCode) }
        set {
            activeLocaleCode = newValue.identifier
            addRecognizer(for: newValue)
        }
    }

    var isRecognizerAvailable: Bool {
        recognizers[activeLocaleCode]?.isAvailable ?? false
    }

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.activeLocaleCode = locale.identifier
        if let rec = SFSpeechRecognizer(locale: locale) {
            self.recognizers[locale.identifier] = rec
        }
    }

    // MARK: - Pool management

    private func addRecognizer(for locale: Locale) {
        let code = locale.identifier
        guard recognizers[code] == nil else { return }
        if let rec = SFSpeechRecognizer(locale: locale) {
            recognizers[code] = rec
        } else {
            onLocaleUnavailable?("Speech recognition is not supported for \(locale.identifier). Please check that the language is downloaded in System Settings → General → Keyboard → Dictation.")
        }
    }

    /// Ensure recognizers exist for all given locale codes and attempt to warm them.
    ///
    /// Call this whenever the set of cycle languages changes, and once after permissions
    /// are granted at startup. Each available recognizer gets a recognition task that is
    /// immediately cancelled — this is a best-effort hint to the framework to load ML
    /// models eagerly. Apple does not document whether task creation alone is sufficient
    /// to trigger model loading; the warm-up may have no effect on some macOS versions.
    /// Recognizers that are unavailable at call time (e.g. mid-download) are skipped
    /// with no retry; their first real use will still incur cold-start latency.
    func prepare(localeCodes: [String]) {
        for code in localeCodes {
            addRecognizer(for: Locale(identifier: code))
        }
        for rec in recognizers.values where rec.isAvailable {
            let req = SFSpeechAudioBufferRecognitionRequest()
            let task = rec.recognitionTask(with: req) { _, _ in }
            task.cancel()
        }
    }

    // MARK: - Permissions

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            if granted {
                                completion(true, nil)
                            } else {
                                completion(false, "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                            }
                        }
                    }
                case .denied, .restricted:
                    completion(false, "Speech recognition denied.\nGrant in System Settings → Privacy & Security → Speech Recognition.")
                case .notDetermined:
                    completion(false, "Speech recognition permission not determined.")
                @unknown default:
                    completion(false, "Unknown speech recognition authorization status.")
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil

        guard let recognizer = recognizers[activeLocaleCode], recognizer.isAvailable else {
            onError?("Speech recognizer not available for \(activeLocaleCode)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // The Speech framework fires this callback on its own internal thread.
            // Dispatch to main so all callbacks touch AppKit only from the main thread.
            DispatchQueue.main.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.onFinalResult?(text)
                    } else {
                        self.onPartialResult?(text)
                    }
                }
                if let error, (error as NSError).code != 216 {
                    self.onError?(error.localizedDescription)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async {
                self?.onAudioLevel?(normalized)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    func stopRecording() {
        // Guard isRunning: if a mid-hold error caused a failed restart, the audio
        // engine may already be stopped and the tap already removed. Calling
        // removeTap on a bus with no tap installed is undefined behaviour.
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest = nil
        recognitionTask = nil
    }
}
