import AVFoundation
import Speech

final class MultiLangSpeechEngine {

    // MARK: - Public interface (mirrors SpeechEngine exactly)

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    init() {}  // explicit init; no setup needed here — startRecording() resets all state

    func startRecording() {}  // implemented in Task 6; resets winnerSelected/counts/dicts
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
}
