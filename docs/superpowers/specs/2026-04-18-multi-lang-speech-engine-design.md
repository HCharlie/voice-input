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

Mirrors the public interface of `SpeechEngine` exactly so `AppDelegate` needs no structural changes:

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

### `AppDelegate` change

```swift
// Before:
private let speechEngine = SpeechEngine()

// After:
private let speechEngine = MultiLangSpeechEngine()
```

`setupSpeechCallbacks()` and all other `AppDelegate` code remain unchanged.

---

## Data Flow

### `startRecording()`

1. Cancel and clear any existing tasks/requests.
2. For each locale in `locales`:
   - Skip if `SFSpeechRecognizer(locale:)` is nil (not downloaded) — log warning.
   - Create `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true` and `addsPunctuation = true` (macOS 13+).
   - Start a recognition task with a result handler (see below).
3. Install a **single tap** on `audioEngine.inputNode`:
   - Append each buffer to **all** active requests.
   - Compute RMS audio level, fire `onAudioLevel`.
4. Start `audioEngine`.

### Recognition task result handler (called per locale)

On each callback:
- If `result != nil`: compute `avgConfidence` from `result.bestTranscription.segments`. Update `candidates[locale]`.
  - Fire `onPartialResult` with the text from whichever candidate currently has the higher `avgConfidence`.
- If `result.isFinal`: mark locale as finished. Start the 50ms winner-selection window (see below).
- If `error != nil` (and not code 216): fire `onError`.

### `stopRecording()`

1. Stop `audioEngine`, remove tap.
2. Call `endAudio()` on all active requests.
3. Let the recognition tasks run to completion — winner is picked when `isFinal` fires (see below).

### Winner selection (on `isFinal`)

When the first `isFinal` arrives, schedule a 50ms `DispatchWorkItem`. When it fires:
- Compare `avgConfidence` of all candidates that have a final result.
- The candidate with the highest `avgConfidence` wins. Ties go to `defaultLocale` (`en-US`).
- Fire `onFinalResult` with the winning text.
- Cancel all remaining tasks immediately.

### `cancel()`

1. Cancel all tasks.
2. Stop `audioEngine` if running, remove tap.
3. Clear all state.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| One recognizer nil (language not downloaded) | Run with the available one only; log warning |
| Both recognizers nil | Fire `onError("No speech recognizers available")` |
| Both confidences equal (e.g. 0.0 at start) | Prefer `en-US` |
| Empty transcript from a recognizer | Ignore that candidate; other wins by default |
| `isFinal` fires from both within 50ms | Compare both, pick higher confidence |
| `isFinal` fires from only one after 50ms window | That one wins regardless |

---

## What Is Not In Scope

- Languages beyond `en-US` and `zh-CN`
- User-configurable language sets
- Showing detected language in the overlay
- Persisting detected language as a preference
- Any changes to `SpeechEngine`, `SettingsWindow`, or the language menu in `AppDelegate`
