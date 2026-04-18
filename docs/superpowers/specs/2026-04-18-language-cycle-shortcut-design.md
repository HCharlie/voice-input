# Language Cycle Shortcut — Design Spec

**Date:** 2026-04-18
**Status:** Approved

## Overview

Add a double-tap `Fn` gesture to cycle through a user-configured subset of languages for voice input. The cycle is configured via checkboxes in the status bar Language submenu.

## 1. Double-tap Detection (`KeyMonitor`)

- Add `onFnDoubleTap: (() -> Void)?` callback.
- On each Fn-down event, compare timestamp against the previous Fn-down using `CACurrentMediaTime()`.
  - If delta ≤ 300ms: fire `onFnDoubleTap`, cancel the pending deferred `onFnDown` timer.
  - If delta > 300ms: start a 300ms deferred timer; fire `onFnDown` when it expires without a second tap.
- Fn-up logic is unchanged.
- Both taps are suppressed (return `nil`) to prevent the emoji picker from appearing.
- State: `lastFnDownTime: Double` and `pendingFnDownTimer: DispatchWorkItem?` added to `KeyMonitor`.

## 2. Language Cycle Logic (`AppDelegate`)

### State
- `cycleLocaleCodes: [String]` — persisted to `UserDefaults` key `"cycleLocaleCodes"`.
- Default on first launch: `["en-US", "zh-CN"]`.

### On `onFnDoubleTap`
1. Guard `isEnabled && !isRecording`.
2. If `cycleLocaleCodes` is empty, do nothing.
3. Find current index of `selectedLocaleCode` in `cycleLocaleCodes`.
4. Advance to next index (modulo count); if current not found, use index 0.
5. Apply via existing `changeLanguage` logic (updates `speechEngine.locale`, `selectedLocaleCode`, and menu checkmarks).
6. Show overlay with language name (e.g. `"Language: 中文 (简体)"`) for 1.2s, then dismiss.
7. Play `"Tink"` sound as feedback.

## 3. Status Bar Menu UI (`AppDelegate`)

The Language submenu gains a new section below a separator:

```
Language
  ● System Default
  ● English (US)             ← bullet/checkmark = currently active
  ● 中文 (简体)
  ● 中文 (繁體)
  ● 日本語
  ● 한국어
  ─────────────────────────
  Double-tap Fn cycles:      ← greyed non-clickable header
  ✓ English (US)             ← checkmark = included in cycle
  ✓ 中文 (简体)
    中文 (繁體)
    日本語
    한국어
```

- Cycle items mirror the full language list minus "System Default".
- Clicking a cycle item toggles its checkmark and updates `cycleLocaleCodes` in `UserDefaults`.
- If all cycle items are unchecked, double-tap Fn does nothing silently.

## 4. Files Changed

| File | Change |
|------|--------|
| `KeyMonitor.swift` | Add `onFnDoubleTap`, double-tap timing logic |
| `AppDelegate.swift` | Wire `onFnDoubleTap`, cycle state, cycle menu section |

No new files required.

## 5. Edge Cases

- **Recording in progress:** double-tap during recording is ignored (`!isRecording` guard).
- **Cycle has one item:** double-tap re-selects same language (no-op effectively).
- **Current language not in cycle:** cycle starts from index 0.
- **Very fast double-tap cancels recording intent:** the 300ms deferred timer means a hold-to-record will only start after the double-tap window passes. This is an acceptable trade-off for ergonomic switching.
