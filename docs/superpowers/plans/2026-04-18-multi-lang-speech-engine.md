# Multi-Language Parallel Speech Engine Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `MultiLangSpeechEngine`, a drop-in replacement for `SpeechEngine` that runs `en-US` and `zh-CN` recognizers in parallel and auto-selects the winner by average segment confidence.

**Architecture:** A new `MultiLangSpeechEngine` class mirrors `SpeechEngine`'s public interface exactly. One `AVAudioEngine` tap feeds audio buffers to two `SFSpeechAudioBufferRecognitionRequest` objects simultaneously. All shared state is serialized on a private serial queue; the winner is chosen by average `SFTranscriptionSegment.confidence` when all tasks complete or a 2-second timeout fires.

**Tech Stack:** Swift 5.9, AVFoundation (`AVAudioEngine`), Speech framework (`SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`), macOS 14+. No new dependencies.

**Note on unit tests:** `SFSpeechRecognitionResult` and `SFTranscriptionSegment` have no public initializers, making the core logic untestable in isolation without heavyweight mocking infrastructure. For this prototype, correctness is verified by `swift build` after each task and a manual integration test at the end.

---

## Chunk 1: Setup and Skeleton

### Task 1: Create the feature branch

**Files:** none

- [ ] **Step 1: Create and switch to the feature branch**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input
git checkout -b feature/multi-lang-parallel-recognizer
```

Expected: `Switched to a new branch 'feature/multi-lang-parallel-recognizer'`

- [ ] **Step 2: Verify clean state**

```bash
git status
```

Expected: no staged or modified tracked files. Untracked files (e.g. the plan document itself) are fine.

---

### Task 2: Create a compilable skeleton of `MultiLangSpeechEngine.swift`

**Files:**
- Create: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

The skeleton declares all types, properties, and method stubs with no logic — just enough to compile. This catches API typos and import issues before any real code is written.

- [ ] **Step 1: Create the skeleton file**

Create `Sources/VoiceInput/MultiLangSpeechEngine.swift` with this content:

```swift
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
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!` (no errors)

- [ ] **Step 3: Commit the skeleton**

```bash
git add Sources/VoiceInput/MultiLangSpeechEngine.swift
git commit -m "feat: add MultiLangSpeechEngine skeleton"
```

---

## Chunk 2: Core Logic

### Task 3: Implement `cleanup()` and `avgConfidence()`

**Files:**
- Modify: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

These are the two building-block helpers. `cleanup()` is the universal state-reset. `avgConfidence(of:)` is the confidence scoring function. Both are called by higher-level methods.

- [ ] **Step 1: Add the private helpers section**

Add the following `// MARK: - Private helpers` section inside the class, after the `defaultLocale` declaration:

```swift
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
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

---

### Task 4: Implement `selectWinner()`

**Files:**
- Modify: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

`selectWinner()` is called when all tasks have reported final results (or the timeout fires). It picks the highest-confidence non-empty candidate, resolves ties in favour of `defaultLocale` (en-US), and dispatches `onFinalResult` to main.

- [ ] **Step 1: Add `selectWinner()` to the private helpers section**

```swift
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
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

---

### Task 5: Implement `handleResult(_:error:locale:)`

**Files:**
- Modify: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

The result handler is called by each `SFSpeechRecognitionTask` on the Speech framework's internal thread. It dispatches `async` onto `stateQueue` for all state access. Key rules:
- `winnerSelected` guard is checked first — all post-cleanup callbacks are silent no-ops.
- When both `result` and `error` are non-nil in the same callback, `result` takes priority (return early after processing result to avoid double-incrementing `finalResultCount`).
- Error code 216 (OS cancellation) is silently ignored and does NOT increment `finalResultCount`.

- [ ] **Step 1: Add `handleResult` to the private helpers section**

```swift
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
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

---

### Task 6: Implement `startRecording()`

**Files:**
- Modify: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

`startRecording()` runs as a single block on `stateQueue`:
1. Calls `cleanup()` first (safe even if nothing is running).
2. Creates recognizers with `isAvailable` check.
3. Installs a single audio tap that feeds all requests simultaneously.
4. Starts `audioEngine` — tap installation must happen BEFORE `start()` (standard Apple pattern).

- [ ] **Step 1: Replace the empty `startRecording()` stub with the full implementation**

```swift
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
                DispatchQueue.main.async { self.onError?("No speech recognizers available") }
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
                DispatchQueue.main.async {
                    self.onError?("Audio engine failed: \(error.localizedDescription)")
                }
                self.cleanup()
            }
        }
    }
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 3: Commit the core logic**

```bash
git add Sources/VoiceInput/MultiLangSpeechEngine.swift
git commit -m "feat: implement MultiLangSpeechEngine core logic"
```

---

## Chunk 3: Wiring and Manual Test

### Task 7: Implement `stopRecording()` and `cancel()`

**Files:**
- Modify: `Sources/VoiceInput/MultiLangSpeechEngine.swift`

Both are called on the main thread by `AppDelegate`. Both remove the audio tap — tap removal **must** happen before `audioEngine.stop()` to prevent the callback from appending to a mid-shutdown request.

- [ ] **Step 1: Replace the empty `stopRecording()` stub**

```swift
    func stopRecording() {
        // Tap removed FIRST — must happen before audioEngine.stop()
        // to prevent in-flight audio callbacks from appending to mid-shutdown requests.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        stateQueue.async { [weak self] in
            guard let self, !self.winnerSelected else { return }
            // Signal end-of-input to all recognizers
            for request in self.requests.values {
                request.endAudio()
            }
            // Safety-net timeout: if a task never fires isFinal, pick whatever we have
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.winnerSelected else { return }
                self.selectWinner()
            }
            self.timeoutWorkItem = item
            self.stateQueue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }
```

- [ ] **Step 2: Replace the empty `cancel()` stub**

```swift
    func cancel() {
        // Tap removed FIRST (same ordering requirement as stopRecording)
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        // Dispatch cleanup async — does NOT fire onFinalResult or onError
        stateQueue.async { [weak self] in self?.cleanup() }
    }
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/VoiceInput/MultiLangSpeechEngine.swift
git commit -m "feat: implement stopRecording and cancel in MultiLangSpeechEngine"
```

---

### Task 8: Wire `AppDelegate.swift`

**Files:**
- Modify: `Sources/VoiceInput/AppDelegate.swift:7`

One-line change. `setupSpeechCallbacks()` and all key-event handlers are unchanged — `MultiLangSpeechEngine` mirrors `SpeechEngine`'s interface exactly, including the no-op `locale` and `onLocaleUnavailable` stubs added in Task 2 that satisfy the compiler without changing behaviour.

- [ ] **Step 1: Swap the engine type in `AppDelegate.swift`**

In `AppDelegate.swift`, find line 7:

```swift
    private let speechEngine = SpeechEngine()
```

Change it to:

```swift
    private let speechEngine = MultiLangSpeechEngine()
```

- [ ] **Step 2: Final build**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/VoiceInput/AppDelegate.swift
git commit -m "feat: swap AppDelegate to use MultiLangSpeechEngine"
```

---

### Task 9: Manual integration test

There is no automated integration test for this feature (system framework dependencies prevent it). Run through this checklist manually by launching the app.

**Launch the app:**

```bash
swift run
```

- [ ] **Test 1 — English speech**
  - Hold Fn, say "Hello, testing one two three", release Fn.
  - Expected: overlay shows English partial results while speaking; text is injected into the focused field.

- [ ] **Test 2 — Chinese speech**
  - Hold Fn, say "你好，测试一二三", release Fn.
  - Expected: overlay shows Chinese partial results; Chinese text is injected.

- [ ] **Test 3 — Language switching mid-session (no crash)**
  - Hold Fn, say a few English words, release Fn.
  - Immediately hold Fn again and say Chinese words.
  - Expected: each session resolves correctly; no crash.

- [ ] **Test 4 — Cancel mid-recording**
  - Hold Fn, say a few words, then disable VoiceInput from the menu bar (toggles `cancel()`).
  - Expected: overlay dismisses; no text is injected; no crash.

- [ ] **Test 5 — Short silence**
  - Hold Fn briefly without speaking, release.
  - Expected: no text injected; overlay dismisses cleanly.

- [ ] **Step: Commit test results note**

```bash
git commit --allow-empty -m "chore: manual integration test complete on feature/multi-lang-parallel-recognizer"
```

---

## Summary

| Task | Files | Commit |
|---|---|---|
| 1 | — | branch created |
| 2 | `MultiLangSpeechEngine.swift` (skeleton) | `feat: add MultiLangSpeechEngine skeleton` |
| 3–6 | `MultiLangSpeechEngine.swift` (core logic) | `feat: implement MultiLangSpeechEngine core logic` |
| 7 | `MultiLangSpeechEngine.swift` (stop/cancel) | `feat: implement stopRecording and cancel in MultiLangSpeechEngine` |
| 8 | `AppDelegate.swift` | `feat: swap AppDelegate to use MultiLangSpeechEngine` |
| 9 | — | manual test note commit |
