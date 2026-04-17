import AVFoundation
import Speech

final class MultiLangSpeechEngine {

    // MARK: - Public interface (mirrors SpeechEngine exactly)

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    init() {}  // explicit init; no setup needed here — startRecording() resets all state

    func startRecording() {
        stateQueue.async { [weak self] in
            guard let self else { return }

            // Step 1: Reset all state
            self.cleanup()
            self.winnerSelected = false
            self.activeTaskCount = 0
            self.finalResultCount = 0

            // Step 2: Create recognizers and tasks for each locale
            for locale in self.locales {
                guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                    NSLog("[MultiLangSpeechEngine] No recognizer for %@", locale.identifier)
                    continue
                }
                guard recognizer.isAvailable else {
                    NSLog("[MultiLangSpeechEngine] Recognizer unavailable for %@", locale.identifier)
                    continue
                }

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                if #available(macOS 13, *) {
                    request.addsPunctuation = true
                }

                let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    self?.handleResult(result, error: error, locale: locale)
                }

                self.recognizers[locale] = recognizer
                self.requests[locale] = request
                self.tasks[locale] = task
                self.activeTaskCount += 1
                // activeTaskCount is fully set before this block exits;
                // handleResult() cannot fire until after this async block completes.
            }

            // Step 3: Bail if no recognizers are available
            guard self.activeTaskCount > 0 else {
                DispatchQueue.main.async { [weak self] in self?.onError?("No speech recognizers available") }
                return
            }

            // Step 4: Obtain hardware format (read after tasks are set up, before tap install)
            let format = self.audioEngine.inputNode.outputFormat(forBus: 0)

            // Step 5: Install single tap — feeds all requests from one audio source
            self.audioEngine.inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format
            ) { [weak self] buffer, _ in
                self?.stateQueue.async { // async — never sync
                    guard let self, !self.winnerSelected else { return }
                    // Append to all active requests.
                    // Appending after endAudio() is a confirmed no-op — safe if stopRecording()
                    // races with an in-flight tap dispatch.
                    for request in self.requests.values {
                        request.append(buffer)
                    }
                    // Compute normalised RMS level for the waveform indicator
                    guard let channelData = buffer.floatChannelData?[0] else { return }
                    let frameLength = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
                    let rms = sqrtf(sum / Float(max(frameLength, 1)))
                    let dB = 20 * log10(max(rms, 1e-6))
                    let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
                    DispatchQueue.main.async { self.onAudioLevel?(normalized) }
                }
            }

            // Step 6: Prepare and start audio engine
            self.audioEngine.prepare()
            do {
                try self.audioEngine.start()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.onError?("Audio engine failed: \(error.localizedDescription)")
                }
                self.cleanup()
            }
        }
    }
    func stopRecording() {}   // implemented in Task 7
    func cancel() {}          // implemented in Task 7

    // No-op stubs — AppDelegate sets these on SpeechEngine; MultiLangSpeechEngine ignores them
    // (language is auto-detected; locale setting and unavailability alerts are irrelevant)
    var locale: Locale = Locale(identifier: "en-US")
    var onLocaleUnavailable: ((String) -> Void)?

    // MARK: - Internal state
    // All reads/writes serialized on stateQueue. Reset on each startRecording() call.

    private let audioEngine = AVAudioEngine()
    private var recognizers: [Locale: SFSpeechRecognizer] = [:]
    private var requests: [Locale: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [Locale: SFSpeechRecognitionTask] = [:]
    private var candidates: [Locale: CandidateResult] = [:]

    private var winnerSelected = false
    private var activeTaskCount = 0
    private var finalResultCount = 0
    private var timeoutWorkItem: DispatchWorkItem?

    // .userInteractive QoS: result handlers arrive on the Speech framework's real-time
    // thread and need to be processed promptly to avoid dropped partial results.
    private let stateQueue = DispatchQueue(
        label: "MultiLangSpeechEngine.state",
        qos: .userInteractive
    )

    private struct CandidateResult {
        var text: String
        var avgConfidence: Float
    }

    private let locales: [Locale] = [
        Locale(identifier: "en-US"),
        Locale(identifier: "zh-CN"),
    ]
    private let defaultLocale = Locale(identifier: "en-US")

    // MARK: - Private helpers

    /// Resets all state. Sets `winnerSelected = true` FIRST so any async dispatches
    /// queued after this point will check the flag and return early.
    /// Call only from the state queue.
    private func cleanup() {
        winnerSelected = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        requests.removeAll()
        recognizers.removeAll()
        candidates.removeAll()
        activeTaskCount = 0
        finalResultCount = 0
        // winnerSelected stays true until startRecording() resets it
    }

    /// Average confidence across all segments. Returns 0.0 for empty-segment results.
    private func avgConfidence(of result: SFSpeechRecognitionResult) -> Float {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return 0.0 }
        return segments.map(\.confidence).reduce(0, +) / Float(segments.count)
    }

    /// Picks the winning candidate and fires `onFinalResult`.
    /// Precondition: called on stateQueue, `winnerSelected == false`.
    private func selectWinner() {
        winnerSelected = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        // Cancel remaining tasks; their handlers receive error 216, which is ignored
        for task in tasks.values { task.cancel() }

        let nonEmpty = candidates.filter { !$0.value.text.isEmpty }
        let best = nonEmpty.max { $0.value.avgConfidence < $1.value.avgConfidence }

        let winner: String
        if let best {
            // Tie: multiple candidates at the same confidence → prefer defaultLocale
            let tied = nonEmpty.filter { $0.value.avgConfidence == best.value.avgConfidence }
            if tied.count > 1,
               let def = candidates[defaultLocale],
               !def.text.isEmpty {
                winner = def.text
            } else {
                winner = best.value.text
            }
        } else {
            // All candidates empty — fallback to defaultLocale (AppDelegate guards empty strings)
            winner = candidates[defaultLocale]?.text ?? ""
        }

        DispatchQueue.main.async { [weak self] in self?.onFinalResult?(winner) }
    }

    /// Result handler called by each SFSpeechRecognitionTask.
    /// Dispatches async onto stateQueue — never sync (prevents re-entrancy deadlock).
    private func handleResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        locale: Locale
    ) {
        stateQueue.async { [weak self] in
            guard let self, !self.winnerSelected else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let avgConf = self.avgConfidence(of: result)
                self.candidates[locale] = CandidateResult(text: text, avgConfidence: avgConf)

                if result.isFinal {
                    // isFinal + any simultaneous error: result takes priority.
                    // `return` prevents the error branch from also incrementing
                    // finalResultCount (double-increment would corrupt the count).
                    self.finalResultCount += 1
                    if self.finalResultCount == self.activeTaskCount {
                        self.timeoutWorkItem?.cancel()
                        self.selectWinner()
                    }
                    return
                } else {
                    // Non-final partial: update overlay, then fall through to error branch.
                    // A simultaneous non-216 error must still be processed so the session
                    // doesn't hang with finalResultCount permanently one short.
                    if let leading = self.candidates.max(by: {
                        $0.value.avgConfidence < $1.value.avgConfidence
                    }), !leading.value.text.isEmpty {
                        DispatchQueue.main.async { self.onPartialResult?(leading.value.text) }
                    }
                    // fall through to error handling
                }
            }

            if let error {
                let code = (error as NSError).code
                if code == 216 {
                    // OS-level cancellation — ignored entirely, no finalResultCount increment.
                    return
                }
                // Non-216: task will not produce isFinal. Count it as done.
                // onError NOT dispatched — preserves per-session contract.
                self.finalResultCount += 1
                if self.finalResultCount == self.activeTaskCount {
                    self.timeoutWorkItem?.cancel()
                    self.selectWinner()
                }
            }
        }
    }
}
