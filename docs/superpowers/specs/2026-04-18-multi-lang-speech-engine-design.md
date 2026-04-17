# Multi-Language Parallel Speech Engine — Design Spec

**Date:** 2026-04-18
**Branch:** feature/multi-lang-parallel-recognizer (new branch, throwaway prototype)
**Status:** Approved

---

## Goal

Automatically detect whether the user is speaking English or Chinese (Simplified) without requiring manual language selection. Run both `SFSpeechRecognizer` instances in parallel on the same audio input and pick the winner by average segment confidence.

---

## Scope

- Languages: `en-US` and `zh-CN`
- New file only: `MultiLangSpeechEngine.swift`
- One-line change in `AppDelegate.swift` to swap in the new engine
- `SpeechEngine.swift` remains untouched
- Prototype branch — no production impact

---

## Architecture

### New class: `MultiLangSpeechEngine`

Mirrors the public interface of `SpeechEngine` exactly:

```swift
var onPartialResult: ((String) -> Void)?
var onFinalResult: ((String) -> Void)?
var onError: ((String) -> Void)?
var onAudioLevel: ((Float) -> Void)?

func startRecording()
func stopRecording()
func cancel()
```

Internal state:

```swift
private let audioEngine = AVAudioEngine()
private var recognizers: [Locale: SFSpeechRecognizer] = [:]
private var requests: [Locale: SFSpeechAudioBufferRecognitionRequest] = [:]
private var tasks: [Locale: SFSpeechRecognitionTask] = [:]
private var candidates: [Locale: CandidateResult] = [:]

private var winnerSelected = false
private var activeTaskCount = 0
private var finalResultCount = 0
private var timeoutWorkItem: DispatchWorkItem?

private struct CandidateResult {
    var text: String
    var avgConfidence: Float
}
```

Hard-coded locales:

```swift
private let locales: [Locale] = [
    Locale(identifier: "en-US"),
    Locale(identifier: "zh-CN")
]
private let defaultLocale = Locale(identifier: "en-US")
```

**Thread safety:** A private serial `DispatchQueue(label: "MultiLangSpeechEngine.state", qos: .userInteractive)` serializes all shared state access. All user-facing callbacks dispatch to `DispatchQueue.main`. Every path that re-enters the state queue from outside (tap block, result handler) uses `async` — never `sync` — to prevent re-entrancy deadlocks.

**`winnerSelected` as universal guard:** `cleanup()` sets `winnerSelected = true` as its very first operation, before touching any other state. All async dispatches that arrive on the state queue after `cleanup()` has run check `winnerSelected` first and return immediately, regardless of what's in the dicts.

**`activeTaskCount` finalization:** All tasks are registered within a single synchronous state queue block in `startRecording()`. Because result handlers are dispatched `async` onto the same serial queue, they cannot execute until after `startRecording()` returns and `activeTaskCount` is fully set. The comparison `finalResultCount == activeTaskCount` is therefore always against the final task count.

**Winner-selection serialization:** Both the count-based trigger (`finalResultCount == activeTaskCount`) and the 2-second timeout trigger call `selectWinner()` from within the serial state queue. The serial queue ensures only one can execute at a time. The first one to run sets `winnerSelected = true`; the second checks `winnerSelected` and returns immediately. No atomic primitives beyond the serial queue are needed.

**Tie-breaking completeness:** The only two locales in this prototype are `en-US` and `zh-CN`. `defaultLocale` is `en-US`. Since `en-US` is always one of the candidates, the tie-breaking rule (prefer `defaultLocale`) is always applicable and produces a deterministic result.

### `AppDelegate` change

```swift
// Before:
private let speechEngine = SpeechEngine()

// After:
private let speechEngine = MultiLangSpeechEngine()
```

**Caller contract per session:**
- Exactly one of `onFinalResult` or `onError` fires — never both.
- `cancel()` fires neither.

---

## Data Flow

### `startRecording()`

Executed as a single block on the state queue (either dispatched to it by the caller, or the caller is on main and this dispatches it):

1. Call `cleanup()`.
2. Set `winnerSelected = false`, `activeTaskCount = 0`, `finalResultCount = 0`.
3. For each locale in `locales`:
   - Create `SFSpeechRecognizer(locale: locale)`. If nil, log warning and skip.
   - Check `recognizer.isAvailable`. If false, log warning and skip.
   - Create `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true` and `addsPunctuation = true` (macOS 13+).
   - Start a recognition task with the result handler below. Store recognizer, request, and task.
   - Increment `activeTaskCount`.
   - *(All tasks are registered before this block exits, so `activeTaskCount` is final before any result handler can fire.)*
4. If `activeTaskCount == 0`: dispatch `onError("No speech recognizers available")` to main; return.
5. `let format = audioEngine.inputNode.outputFormat(forBus: 0)`.
6. `audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format)` with a block that:
   - Dispatches `async` onto the state queue.
   - Checks `winnerSelected`; if true, returns immediately.
   - Appends buffer to all stored requests. *(Appending after `endAudio()` is a confirmed no-op.)*
   - Computes RMS; dispatches `onAudioLevel` to main.
7. `audioEngine.prepare()`. `try audioEngine.start()`. On throw: dispatch `onError` to main, `cleanup()`, return.

### Recognition task result handler (per locale)

Called by Speech framework on its internal thread. Dispatches **async** onto the state queue — never sync.

**Important:** `SFSpeechRecognitionTask` can deliver a non-nil `result` and a non-nil `error` in the same callback invocation. When both are present, **result takes priority** and the error is ignored for that invocation. This prevents double-incrementing `finalResultCount` which would cause the session to hang with no callback ever firing.

```
on the state queue:
  if winnerSelected → return

  if let result:
    text = result.bestTranscription.formattedString
    avgConf = avgConfidence(of: result)
    candidates[locale] = CandidateResult(text: text, avgConfidence: avgConf)

    if result.isFinal:
      // isFinal + any simultaneous error: result takes priority.
      // return prevents error branch from also incrementing finalResultCount.
      finalResultCount += 1
      if finalResultCount == activeTaskCount:
        timeoutWorkItem?.cancel()
        selectWinner()
      return
    else:
      // Non-final partial: update overlay, then fall through to error branch.
      // A simultaneous non-216 error must still be processed.
      leading = candidates.max { $0.value.avgConfidence < $1.value.avgConfidence }
      if let leading, !leading.value.text.isEmpty:
        dispatch onPartialResult(leading.value.text) to main
      // fall through to error handling

  // No result — process error only
  if let error:
    let code = (error as NSError).code
    if code == 216:
      return  // OS-level cancellation — ignored entirely, does NOT increment finalResultCount
               // Prevents premature selectWinner() from task.cancel() calls in selectWinner()
    // Non-216 error: task will not produce isFinal; count it as done
    // onError is NOT dispatched here — even if other tasks are still running — to preserve
    // the caller contract (exactly one of onFinalResult/onError fires per session).
    // Intermediate task failures are silently absorbed; selectWinner() handles the outcome.
    finalResultCount += 1
    if finalResultCount == activeTaskCount:
      timeoutWorkItem?.cancel()
      selectWinner()  // fires onFinalResult with best available candidates (may be empty)
```

### `stopRecording()`

Called on main thread by `AppDelegate`.

1. **Remove tap from `audioEngine.inputNode` first** — this must happen before `audioEngine.stop()` to prevent the audio callback from appending buffers to requests that are mid-shutdown.
2. Stop `audioEngine`.
3. Dispatch **async** onto state queue:
   - If `winnerSelected`: return (already cancelled — do not call `endAudio()` on cleared requests).
   - Call `endAudio()` on all stored requests.
   - Schedule `timeoutWorkItem` on state queue 2s later:
     ```
     let item = DispatchWorkItem { [weak self] in
         guard let self, !self.winnerSelected else { return }
         self.selectWinner()
     }
     timeoutWorkItem = item
     stateQueue.asyncAfter(deadline: .now() + 2.0, execute: item)
     ```

### `selectWinner()` — internal helper (state queue only, called when `!winnerSelected`)

```
winnerSelected = true
timeoutWorkItem?.cancel(); timeoutWorkItem = nil

// Cancel remaining tasks → their result handlers will receive error 216 → ignored
for task in tasks.values { task.cancel() }

// Pick highest-confidence non-empty candidate
best = candidates
  .filter { !$0.value.text.isEmpty }
  .max { $0.value.avgConfidence < $1.value.avgConfidence }

// Tie resolution: if best is tied with another non-empty candidate, prefer defaultLocale
// (en-US is always one of the two locales in this prototype, so this always applies)
let tiedCandidates = candidates.filter {
    !$0.value.text.isEmpty && $0.value.avgConfidence == best?.value.avgConfidence
}
let winner: String
if tiedCandidates.count > 1, let def = candidates[defaultLocale], !def.text.isEmpty {
    winner = def.text
} else {
    winner = best?.value.text ?? candidates[defaultLocale]?.text ?? ""
}

dispatch onFinalResult(winner) to main
```

### `cancel()`

Called on main thread by `AppDelegate`.

1. Remove tap from `audioEngine.inputNode` (if running).
2. Stop `audioEngine` (if running).
3. Dispatch **async** onto state queue: call `cleanup()`.
4. Does not fire `onFinalResult` or `onError`.

### `cleanup()` — internal helper (state queue only)

```
// winnerSelected set FIRST — all subsequent async dispatches will early-return
winnerSelected = true

timeoutWorkItem?.cancel(); timeoutWorkItem = nil
for task in tasks.values { task.cancel() }
tasks.removeAll()
requests.removeAll()
recognizers.removeAll()
candidates.removeAll()
activeTaskCount = 0
finalResultCount = 0
// winnerSelected stays true until startRecording() resets it in step 2
```

---

## Confidence Computation

```swift
func avgConfidence(of result: SFSpeechRecognitionResult) -> Float {
    let segments = result.bestTranscription.segments
    guard !segments.isEmpty else { return 0.0 }
    return segments.map(\.confidence).reduce(0, +) / Float(segments.count)
}
```

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| One recognizer nil or unavailable | Run with available one; log warning |
| Both nil or unavailable | `onError` on main; no audio started |
| `audioEngine.start()` throws | `onError` on main; `cleanup()` |
| One task errors non-216, other succeeds | Error silently absorbed; `onFinalResult` fires when all tasks done |
| All tasks errored non-216 | `selectWinner()` fires `onFinalResult` with best/empty candidate |
| Equal `avgConfidence` | `defaultLocale` (en-US) wins; always applicable in this prototype |
| All candidates empty | `candidates[defaultLocale]?.text ?? ""`; AppDelegate guards empty |
| Zero segments | `avgConfidence` = 0.0 |
| All `isFinal` before timeout | Immediate `selectWinner()`; timeout cancelled |
| One task errors 216 (from cancel) | Ignored; no count increment |
| Timeout fires | `selectWinner()` with available candidates |
| Late `isFinal` / error after winner | `winnerSelected` guard: no-op |
| `cancel()` during timeout window | `cleanup()` cancels timeout; no callbacks |
| `startRecording()` after `cancel()` | `cleanup()` in step 1 resets all state |
| Tap dispatches after `cleanup()` | `winnerSelected = true` → early return |
| Tap dispatches after `endAudio()` | Append is a no-op; harmless |
| Count trigger and timeout trigger race | Serial queue serializes them; first sets `winnerSelected = true`; second returns |

---

## What Is Not In Scope

- Languages beyond `en-US` and `zh-CN`
- User-configurable language sets
- Showing detected language in the overlay
- Persisting detected language as a preference
- Any changes to `SpeechEngine`, `SettingsWindow`, or the language menu in `AppDelegate`
