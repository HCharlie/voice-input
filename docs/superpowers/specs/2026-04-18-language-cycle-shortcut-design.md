# Language Cycle Shortcut — Design Spec

**Date:** 2026-04-18
**Status:** Approved (rev 4)

## Overview

Add a double-tap `Fn` gesture to cycle through a user-configured subset of languages for voice input. The cycle is configured via checkboxes in the status bar Language submenu.

## 1. Double-tap Detection (`KeyMonitor`)

### New callbacks
- `onFnDoubleTap: (() -> Void)?`

### New state (private, on `KeyMonitor`)
- `lastFnDownTime: Double = 0` — `CACurrentMediaTime()` of most recent Fn-down
- `lastFnUpTime: Double = 0`   — `CACurrentMediaTime()` of most recent Fn-up
- `suppressNextFnUp: Bool = false` — set when double-tap is detected; suppresses the paired Fn-up

### Updated `handle(type:event:)` — complete flow

All timestamp sampling occurs synchronously before any `DispatchQueue.main.async`.

**Fn-down (`fnDown && !fnPressed`):**
```
let now = CACurrentMediaTime()
let gapBetweenTaps  = now - lastFnDownTime
let prevTapDuration = lastFnUpTime - lastFnDownTime

if gapBetweenTaps < 0.40 && prevTapDuration > 0 && prevTapDuration < 0.30 {
    // Double-tap: short gap and previous tap was short
    // Set fnPressed = true so the paired Fn-up enters the normal branch and
    // records lastFnUpTime correctly (and is suppressed by the flag below).
    fnPressed = true
    suppressNextFnUp = true
    // Do NOT update lastFnDownTime — prevents triple-tap re-triggering
    DispatchQueue.main.async { self.onFnDoubleTap?() }
} else {
    lastFnDownTime = now
    fnPressed = true
    DispatchQueue.main.async { self.onFnDown?() }
}
return nil  // suppress both branches
```

**Fn-up (`!fnDown && fnPressed`):**
```
let now = CACurrentMediaTime()
lastFnUpTime = now   // always record; needed for future double-tap detection
fnPressed = false

if suppressNextFnUp {
    suppressNextFnUp = false
    return nil       // suppress Fn-up for the second tap; do not fire onFnUp
}

DispatchQueue.main.async { self.onFnUp?() }
return nil
```

### Behaviour notes
- `fnPressed = true` is set in **both** branches of the Fn-down handler so that the paired Fn-up always enters the `!fnDown && fnPressed` branch, correctly recording `lastFnUpTime` and decrementing `fnPressed`.
- The first tap of a double-tap fires `onFnDown` + `onFnUp` normally (brief recording < 300ms). `fnDoubleTap()` in AppDelegate cancels `finalResultTimer` and calls `speechEngine.cancel()` before switching language, so no transcription is injected.
- Normal hold-to-record: `onFnDown` fires immediately — no added latency.
- Both Fn events are suppressed (`return nil`) to prevent the emoji picker.

## 2. Language Cycle Logic (`AppDelegate`)

### Promote `languages` to a stored property
The `languages` constant is currently a local `let` inside `setupStatusBar()`. Promote it to a stored property so it can be accessed from `toggleCycle(_:)` and `languageName(for:)`:
```swift
private let languages: [(name: String, code: String)] = [
    (name: "System Default", code: ""),
    (name: "English (US)",   code: "en-US"),
    (name: "中文 (简体)",     code: "zh-CN"),
    (name: "中文 (繁體)",     code: "zh-TW"),
    (name: "日本語",          code: "ja-JP"),
    (name: "한국어",          code: "ko-KR"),
]
```
Update `setupStatusBar()` to reference `self.languages`. The existing `for (name, code) in languages` loop body is unchanged — Swift positional destructuring works with named tuples.

### New state
```swift
// Computed property — same pattern as selectedLocaleCode
private var cycleLocaleCodes: [String] {
    get {
        (UserDefaults.standard.array(forKey: "cycleLocaleCodes") as? [String])
            ?? ["en-US", "zh-CN"]
    }
    set { UserDefaults.standard.set(newValue, forKey: "cycleLocaleCodes") }
}

private var languageSwitchDismissTimer: Timer?
private var cycleMenuItems: [NSMenuItem] = []   // parallel to languageItems
```

### Helper method: `setLanguage(code:)`
Extract a private helper containing the three lines currently in `changeLanguage(_:)`:
```swift
private func setLanguage(code: String) {
    selectedLocaleCode = code
    speechEngine.locale = code.isEmpty ? .current : Locale(identifier: code)
    for item in languageItems {
        item.state = (item.representedObject as? String) == code ? .on : .off
    }
}
```
`setLanguage(code:)` does **not** call `updateCycleMenuItems()` — active-language selection and cycle membership are orthogonal. `updateCycleMenuItems()` is called only from `fnDoubleTap()` and `toggleCycle(_:)`.

Update `changeLanguage(_:)` to delegate to `setLanguage(code:)`.

### Helper method: `languageName(for:)`
```swift
private func languageName(for code: String) -> String {
    languages.first(where: { $0.code == code })?.name ?? code
}
```

### Wire `onFnDoubleTap` in `applicationDidFinishLaunching`
```swift
keyMonitor.onFnDoubleTap = { [weak self] in self?.fnDoubleTap() }
```

### `fnDoubleTap()` implementation
```swift
private func fnDoubleTap() {
    guard isEnabled, !isRecording else { return }

    // Ordering guarantee: the CGEvent tap is added to CFRunLoopGetMain(), so handle() runs
    // synchronously on the main thread. All three DispatchQueue.main.async dispatches
    // (onFnDown, onFnUp, onFnDoubleTap) are enqueued in FIFO order and execute sequentially
    // after the current run-loop iteration. By the time fnDoubleTap() runs, fnUp() has
    // already completed and finalResultTimer is set — so the invalidate below is not a no-op.
    //
    // speechEngine.cancel() is safe when idle: SpeechEngine.cancel() uses optional-chaining
    // on recognitionTask and an `audioEngine.isRunning` guard in cleanup() (SpeechEngine.swift:124-136).
    finalResultTimer?.invalidate()
    finalResultTimer = nil
    speechEngine.cancel()
    lastPartialResult = ""

    guard !cycleLocaleCodes.isEmpty else { return }

    let currentIndex = cycleLocaleCodes.firstIndex(of: selectedLocaleCode)
    let nextIndex = currentIndex.map { ($0 + 1) % cycleLocaleCodes.count } ?? 0
    let nextCode = cycleLocaleCodes[nextIndex]

    setLanguage(code: nextCode)
    updateCycleMenuItems()

    // overlayPanel.show(text:) resets label text and waveform; no prior dismiss() needed.
    overlayPanel.show(text: "Language: \(languageName(for: nextCode))")
    NSSound(named: .init("Tink"))?.play()

    languageSwitchDismissTimer?.invalidate()
    languageSwitchDismissTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
        self?.overlayPanel.dismiss()
        self?.languageSwitchDismissTimer = nil
    }
}
```

Cancel the dismiss timer when recording starts (add to top of `fnDown()`):
```swift
private func fnDown() {
    languageSwitchDismissTimer?.invalidate()
    languageSwitchDismissTimer = nil
    // overlayPanel.show(text: "Listening...") below replaces any visible overlay content
    // (same behaviour as in fnDoubleTap — show() resets label and waveform in-place).
    // ... existing recording logic unchanged
}
```

### Edge cases
- `cycleLocaleCodes` empty → `fnDoubleTap()` returns after the guard; no crash.
- Cycle has one item → double-tap re-applies the same language (no-op; no error).
- Active language not in cycle → `firstIndex` returns `nil` → falls back to index 0.
- Recording in progress → `isRecording` guard skips the switch.
- Language-switch overlay visible when recording starts → `fnDown()` cancels `languageSwitchDismissTimer`; `overlayPanel.show(text: "Listening...")` replaces the content.

## 3. Status Bar Menu UI (`AppDelegate`)

### Language submenu layout
```
Language
  ● System Default
  ● English (US)             ← checkmark = currently active
  ● 中文 (简体)
  ● 中文 (繁體)
  ● 日本語
  ● 한국어
  ─────────────────────────
  Double-tap Fn cycles:      ← NSMenuItem with isEnabled=false (greyed header)
  ✓ English (US)             ← checkmark = included in cycle
  ✓ 中文 (简体)
    中文 (繁體)
    日本語
    한국어
```

Cycle items mirror `languages` minus the "System Default" entry (empty code). Built in `setupStatusBar()`, stored in `cycleMenuItems`. Each item's `.state` is set inline during construction (`.on` if in `cycleLocaleCodes`, `.off` otherwise) — do **not** add a separate `updateCycleMenuItems()` call in `setupStatusBar()`; the inline assignment is sufficient.

### Cycle item toggle: `@objc func toggleCycle(_ sender: NSMenuItem)`
```swift
@objc private func toggleCycle(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    if cycleLocaleCodes.contains(code) {
        cycleLocaleCodes.removeAll { $0 == code }
    } else {
        // Insert preserving canonical order from languages array
        let order = languages.compactMap { $0.code.isEmpty ? nil : $0.code }
        let insertIndex = order.firstIndex(of: code).flatMap { idx in
            cycleLocaleCodes.firstIndex { c in
                (order.firstIndex(of: c) ?? Int.max) > idx
            }
        } ?? cycleLocaleCodes.endIndex
        cycleLocaleCodes.insert(code, at: insertIndex)
    }
    updateCycleMenuItems()
}
```

### `updateCycleMenuItems()`
```swift
private func updateCycleMenuItems() {
    for item in cycleMenuItems {
        guard let code = item.representedObject as? String else { continue }
        item.state = cycleLocaleCodes.contains(code) ? .on : .off
    }
}
```

## 4. Files Changed

| File | Change |
|------|--------|
| `KeyMonitor.swift` | Add `onFnDoubleTap`, `lastFnDownTime`, `lastFnUpTime`, `suppressNextFnUp`; update `handle()` |
| `AppDelegate.swift` | Promote `languages` to stored property; extract `setLanguage(code:)`; add `cycleLocaleCodes`, `cycleMenuItems`, `languageSwitchDismissTimer`; add `fnDoubleTap()`, `toggleCycle(_:)`, `updateCycleMenuItems()`, `languageName(for:)`; cancel dismiss timer in `fnDown()`; expand Language submenu in `setupStatusBar()` |

No new files required.
