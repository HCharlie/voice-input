# Language Cycle Shortcut Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a double-tap `Fn` gesture that cycles through a user-selected subset of voice input languages, configured via checkboxes in the status bar Language submenu.

**Architecture:** Double-tap detection lives entirely in `KeyMonitor` using timestamp comparison on consecutive Fn-down events (synchronous in the CGEventTap callback). `AppDelegate` handles the language cycle state and UI updates. Two files change; no new files needed.

**Tech Stack:** Swift 5.9, macOS 14+, AppKit, CGEventTap, UserDefaults

**Spec:** `docs/superpowers/specs/2026-04-18-language-cycle-shortcut-design.md`

**Chunk order dependency:** Chunks must be applied in order (1 → 2 → 3 → 4 → 5). Chunk 3 inserts after properties added in Chunk 2; Chunk 4's submenu loop references `self.languages` which is promoted in Chunk 2.

---

## Chunk 1: KeyMonitor double-tap detection

### Task 1: Add double-tap state and callback to `KeyMonitor`

**Files:**
- Modify: `Sources/VoiceInput/KeyMonitor.swift`

Note: `CACurrentMediaTime` is available via `Cocoa`'s transitive import of `QuartzCore` on macOS — no extra import needed.

- [ ] **Step 1: Add new state variables and callback**

Open `Sources/VoiceInput/KeyMonitor.swift`. After the existing `private var fnPressed = false` line (line 9), add:

```swift
var onFnDoubleTap: (() -> Void)?

private var lastFnDownTime: Double = 0
private var lastFnUpTime: Double = 0
private var suppressNextFnUp: Bool = false
```

- [ ] **Step 2: Update the Fn-down branch in `handle(type:event:)`**

Find the Fn-down branch (currently lines 64-67):
```swift
if fnDown && !fnPressed {
    fnPressed = true
    DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
    return nil // suppress Fn press (prevents emoji picker)
```

Replace with:
```swift
if fnDown && !fnPressed {
    let now = CACurrentMediaTime()
    let gapBetweenTaps  = now - lastFnDownTime
    let prevTapDuration = lastFnUpTime - lastFnDownTime

    if gapBetweenTaps < 0.40 && prevTapDuration > 0 && prevTapDuration < 0.30 {
        // Second tap of a double-tap. Set fnPressed so the paired Fn-up
        // enters the normal branch and records lastFnUpTime correctly.
        fnPressed = true
        suppressNextFnUp = true
        // Do NOT update lastFnDownTime — prevents triple-tap re-triggering.
        DispatchQueue.main.async { [weak self] in self?.onFnDoubleTap?() }
    } else {
        lastFnDownTime = now
        fnPressed = true
        DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
    }
    return nil // suppress Fn press (prevents emoji picker)
```

- [ ] **Step 3: Update the Fn-up branch in `handle(type:event:)`**

Find the Fn-up branch (currently lines 68-71):
```swift
} else if !fnDown && fnPressed {
    fnPressed = false
    DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
    return nil // suppress Fn release
```

Replace with:
```swift
} else if !fnDown && fnPressed {
    let now = CACurrentMediaTime()
    lastFnUpTime = now  // always record for future double-tap detection
    fnPressed = false

    if suppressNextFnUp {
        suppressNextFnUp = false
        return nil  // suppress Fn-up for the second tap; do not fire onFnUp
    }

    DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
    return nil // suppress Fn release
```

- [ ] **Step 4: Build and verify it compiles**

```bash
cd /Users/changlihan/src/github.com/HCharlie/voice-input
swift build 2>&1
```
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceInput/KeyMonitor.swift
git commit -m "feat: add double-tap Fn detection to KeyMonitor"
```

---

## Chunk 2: AppDelegate — language stored property and setLanguage helper

### Task 2: Promote `languages` and extract `setLanguage(code:)`

**Files:**
- Modify: `Sources/VoiceInput/AppDelegate.swift`

- [ ] **Step 1: Promote `languages` to a stored property**

In `AppDelegate`, add this stored property after the `private var languageItems: [NSMenuItem] = []` line (currently line 20):

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

- [ ] **Step 2: Remove the local `languages` constant from `setupStatusBar()`**

In `setupStatusBar()`, find and delete the local `let languages: [(String, String)] = [...]` declaration (currently lines 226-233). The `for (name, code) in languages` loop that follows references `self.languages` — Swift positional destructuring works unchanged with named tuples.

- [ ] **Step 3: Extract `setLanguage(code:)` helper**

Add a new private method in the `// MARK: - Actions` section, before `changeLanguage(_:)`:

```swift
private func setLanguage(code: String) {
    selectedLocaleCode = code
    speechEngine.locale = code.isEmpty ? .current : Locale(identifier: code)
    for item in languageItems {
        item.state = (item.representedObject as? String) == code ? .on : .off
    }
}
```

`setLanguage(code:)` intentionally does NOT call `updateCycleMenuItems()` — active-language selection and cycle membership are orthogonal concerns.

- [ ] **Step 4: Update `changeLanguage(_:)` to use the helper**

Find `changeLanguage(_:)` (currently lines 306-313). Replace its body:

```swift
@objc private func changeLanguage(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    setLanguage(code: code)
}
```

- [ ] **Step 5: Build and verify**

```bash
swift build 2>&1
```
Expected: `Build complete!` — same behaviour as before, just refactored.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoiceInput/AppDelegate.swift
git commit -m "refactor: promote languages to stored property and extract setLanguage helper"
```

---

## Chunk 3: AppDelegate — cycle state and fnDoubleTap

### Task 3: Add cycle state, helpers, and `fnDoubleTap()`

**Files:**
- Modify: `Sources/VoiceInput/AppDelegate.swift`

Note: By this point Chunk 2 has already been applied, so line numbers in the file have shifted from the original source. Use the prose descriptions (property names, method names) to locate insertion points — do not rely on line numbers.

- [ ] **Step 1: Verify `speechEngine` type and `cancel()` safety**

`AppDelegate.swift` line 7 declares `private let speechEngine = MultiLangSpeechEngine()`.

`MultiLangSpeechEngine.cancel()` is at `Sources/VoiceInput/MultiLangSpeechEngine.swift:124-130`:
```swift
func cancel() {
    audioEngine.inputNode.removeTap(onBus: 0)  // safe if no tap installed
    if audioEngine.isRunning { audioEngine.stop() }  // guarded
    stateQueue.async { [weak self] in self?.cleanup() }
}
```
This is safe to call when idle.

**Important caveat:** `MultiLangSpeechEngine.locale` (line 134) is a no-op stub — the engine hardcodes `locales = [en-US, zh-CN]` and auto-detects between them, ignoring the `locale` property entirely. This means `setLanguage(code:)` will set `selectedLocaleCode` (persisted preference, shown in menu) and call `speechEngine.locale = ...` (harmless no-op). The cycle feature works as a **UI preference** — the overlay and menu correctly reflect the user's language choice, but actual transcription behaviour is unaffected for en-US/zh-CN (both always active), and zh-TW/ja-JP/ko-KR are not supported by this engine. This is an acceptable trade-off for now.

- [ ] **Step 2: Add cycle state properties**

After the `private var selectedLocaleCode: String { ... }` computed property, add:

```swift
private var cycleLocaleCodes: [String] {
    get {
        (UserDefaults.standard.array(forKey: "cycleLocaleCodes") as? [String])
            ?? ["en-US", "zh-CN"]
    }
    set { UserDefaults.standard.set(newValue, forKey: "cycleLocaleCodes") }
}

private var languageSwitchDismissTimer: Timer?
private var cycleMenuItems: [NSMenuItem] = []
```

- [ ] **Step 3: Add `languageName(for:)` helper**

Add in the `// MARK: - Actions` section:

```swift
private func languageName(for code: String) -> String {
    languages.first(where: { $0.code == code })?.name ?? code
}
```

- [ ] **Step 4: Add `updateCycleMenuItems()` helper**

```swift
private func updateCycleMenuItems() {
    for item in cycleMenuItems {
        guard let code = item.representedObject as? String else { continue }
        item.state = cycleLocaleCodes.contains(code) ? .on : .off
    }
}
```

- [ ] **Step 5: Add `fnDoubleTap()` implementation**

Add in the `// MARK: - Key events` section, after `fnUp()`:

```swift
private func fnDoubleTap() {
    guard isEnabled, !isRecording else { return }

    // Ordering guarantee: the CGEvent tap runs on CFRunLoopGetMain(), so all three
    // DispatchQueue.main.async dispatches (onFnDown, onFnUp, onFnDoubleTap) execute
    // in FIFO order. fnUp() always completes before fnDoubleTap() runs, so
    // finalResultTimer is already set by the time we cancel it here.
    //
    // speechEngine is MultiLangSpeechEngine. cancel() is safe when idle:
    // removeTap() is a no-op if no tap installed; audioEngine.stop() is guarded by
    // isRunning check (MultiLangSpeechEngine.swift:124-130).
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

    // Race note: onFinalResult from the speech framework can be dispatched to the main
    // queue between fnUp() and fnDoubleTap() (both FIFO on main queue). If onFinalResult
    // fires before fnDoubleTap(), finishTranscription() runs first. In practice this is
    // self-healing: the first tap is < 300ms of audio (user not yet speaking), so the
    // transcription is empty and finishTranscription() bails at its `guard !text.isEmpty`
    // check — no text is injected. The subsequent speechEngine.cancel() above then cleans up.
    //
    // The first tap of the double-tap will have shown "Listening..." in the overlay.
    // overlayPanel.show(text:) re-runs the appear animation (alpha 0 → 1), which causes
    // a brief fade-reset. This is intentional and acceptable — the user just double-tapped.
    overlayPanel.show(text: "Language: \(languageName(for: nextCode))")
    // Note: the user will hear two Tink sounds in quick succession — one from fnDown()
    // on the first tap and one here. This is the intended feedback for a double-tap.
    NSSound(named: .init("Tink"))?.play()

    languageSwitchDismissTimer?.invalidate()
    languageSwitchDismissTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
        self?.overlayPanel.dismiss()
        self?.languageSwitchDismissTimer = nil
    }
}
```

- [ ] **Step 6: Cancel the dismiss timer in `fnDown()`**

At the very top of `fnDown()`, before any existing code, add:

```swift
// Cancel any pending language-switch overlay dismiss — the recording overlay
// will replace it via overlayPanel.show(text: "Listening...") below.
languageSwitchDismissTimer?.invalidate()
languageSwitchDismissTimer = nil
```

This runs unconditionally (before the `guard isEnabled, !isRecording` check) because the timer should be cancelled regardless of whether recording actually starts.

- [ ] **Step 7: Wire `onFnDoubleTap` in `applicationDidFinishLaunching`**

After the existing `keyMonitor.onFnUp` assignment, add:

```swift
keyMonitor.onFnDoubleTap = { [weak self] in self?.fnDoubleTap() }
```

- [ ] **Step 8: Build and verify**

```bash
swift build 2>&1
```
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
git add Sources/VoiceInput/AppDelegate.swift
git commit -m "feat: add fnDoubleTap, cycle state, and language helpers to AppDelegate"
```

---

## Chunk 4: AppDelegate — cycle submenu section

### Task 4: Add `toggleCycle(_:)` and cycle submenu items

**Files:**
- Modify: `Sources/VoiceInput/AppDelegate.swift`

Prerequisite: Chunk 2 must be applied first — `self.languages` (stored property) must exist before the loop in Step 2 below compiles.

- [ ] **Step 1: Add `toggleCycle(_:)` action**

Add in the `// MARK: - Actions` section:

```swift
@objc private func toggleCycle(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    if cycleLocaleCodes.contains(code) {
        cycleLocaleCodes.removeAll { $0 == code }
    } else {
        // Insert preserving canonical order from the languages array.
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

- [ ] **Step 2: Add cycle submenu section in `setupStatusBar()`**

In `setupStatusBar()`, find where `langItem.submenu = langMenu` is assigned (the line immediately before `menu.addItem(langItem)`). Insert the following block **before** that line:

```swift
langMenu.addItem(.separator())

let cycleHeader = NSMenuItem(title: "Double-tap Fn cycles:", action: nil, keyEquivalent: "")
cycleHeader.isEnabled = false
langMenu.addItem(cycleHeader)

for (name, code) in languages where !code.isEmpty {
    let item = NSMenuItem(title: name, action: #selector(toggleCycle(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = code
    item.state = cycleLocaleCodes.contains(code) ? .on : .off  // initialise from UserDefaults
    cycleMenuItems.append(item)
    langMenu.addItem(item)
}
```

The cycle section will show: a separator, a greyed non-clickable "Double-tap Fn cycles:" header, then 5 language items (no System Default entry). The `.state` is set inline during construction so checkboxes reflect `UserDefaults` state on first open.

- [ ] **Step 3: Build and verify**

```bash
swift build 2>&1
```
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/VoiceInput/AppDelegate.swift
git commit -m "feat: add cycle language submenu section with checkboxes"
```

---

## Chunk 5: Manual verification

### Task 5: End-to-end manual test

**No source changes — verification only.**

- [ ] **Step 1: Run the app**

```bash
swift run
```
Or build and launch from Finder. Grant Accessibility permission if prompted.

- [ ] **Step 2: Verify Language submenu layout**

Click the status bar mic icon → Language. Confirm:
- Top section: 6 items (System Default through 한국어), active language has a checkmark
- Separator
- Greyed "Double-tap Fn cycles:" header (non-clickable)
- 5 language items (no System Default): English (US) and 中文 (简体) have checkmarks, others do not

- [ ] **Step 3: Verify cycle checkbox toggle and ordering**

a. Click "中文 (繁體)" in the cycle section. Confirm its checkmark appears.
b. Close and reopen the menu — checkmark persists (UserDefaults).
c. Click "中文 (繁體)" again — checkmark disappears.
d. **Order invariant test:** With cycle = [en-US, zh-CN], check "日本語" → cycle should be [en-US, zh-CN, ja-JP] (canonical order). Then uncheck zh-CN → [en-US, ja-JP]. Then re-check zh-CN → should restore to [en-US, zh-CN, ja-JP], not [en-US, ja-JP, zh-CN]. Verify by double-tapping Fn repeatedly and watching which language is selected in sequence.

- [ ] **Step 4: Verify `changeLanguage` refactor (regression)**

Click "日本語" in the **top** Language section (not the cycle section). Confirm:
- Active checkmark moves to 日本語
- Cycle section checkmarks are **unchanged** (setLanguage does not affect cycle membership)
- Voice input now transcribes in Japanese (if language is downloaded)

- [ ] **Step 5: Verify double-tap Fn cycles language**

Reset active language to English (US). Keep cycle = [en-US, zh-CN]:
1. Double-tap Fn quickly (two short taps, < 400ms apart, each tap < 300ms long)
2. Expect: two Tink sounds in quick succession (first from recording start, second from language switch), overlay shows "Language: 中文 (简体)", dismisses after ~1.2s
3. Open Language menu — 中文 (简体) now has the active checkmark

Double-tap again → cycles back to English (US).

- [ ] **Step 6: Verify hold-to-record still works with no extra latency**

Press and hold Fn for ~2 seconds, speak a word, release.
Expect: recording starts immediately on press (no 300ms delay), transcription is injected as before.

- [ ] **Step 7: Verify language-switch overlay is replaced by recording overlay**

Double-tap Fn to show language overlay. Within 1.2s, press-and-hold Fn to record.
Expect: overlay transitions to "Listening..." with a brief fade-reset (normal — `show()` re-runs the appear animation). No stale "Language:..." text remains.

- [ ] **Step 8: Verify empty cycle is a no-op**

Uncheck all 5 languages in the cycle section. Double-tap Fn. Expect: nothing happens, no crash, no overlay.

- [ ] **Step 9: Verify double-tap with one cycle item**

Leave only "English (US)" in the cycle. Double-tap Fn. Expect: overlay shows "Language: English (US)", language is re-applied (no-op effectively), no crash.

- [ ] **Step 10: Verify active language not in cycle falls back to index 0**

Set active language to "日本語" (via top menu). Ensure cycle = [en-US, zh-CN]. Double-tap Fn. Expect: cycles to en-US (index 0 fallback, since ja-JP is not in cycle).

- [ ] **Step 11: Final commit if any last-minute fixes were made**

```bash
git status
# commit any fixes with appropriate message
```
