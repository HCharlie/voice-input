# Transcription History Feature — Design Spec

**Date:** 2026-04-12
**Status:** Approved

## Overview

Add a persistent transcription history to VoiceInput so users can review, copy, and re-inject past transcriptions. Useful when context is lost (e.g. during a long Claude Code session) and the user needs to recall what they previously dictated.

## Requirements

- Store all transcriptions for the last 7 days; automatically purge older entries
- Dedicated history window accessible via "History..." in the status bar menu
- Search bar to filter entries by text content
- Per-entry actions: Copy to clipboard and Re-inject into focused app
- Mark entries that were modified by LLM refinement
- Future consideration: Clipy clipboard manager integration (copy each transcription to clipboard automatically so it appears in Clipy's history)

## Data Model

### `TranscriptionEntry`

```swift
struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let text: String       // the final injected text (post-refinement if refined)
    let date: Date
    var wasRefined: Bool   // true only if LLM refinement succeeded AND changed the text
                           // false if refinement was disabled, failed, or produced no change
                           // (original pre-refinement text is intentionally not stored)
}
```

### Storage

- **File:** `~/Library/Application Support/VoiceInput/history.json`
- **Format:** JSON array of `TranscriptionEntry` objects
- **Retention:** 7 days rolling; entries older than 7 days are purged
- **Threading:** All operations are main-thread-only. File I/O is synchronous on the main thread. This is acceptable given the small data size and infrequent writes.

## Architecture

### New Files

#### `TranscriptionEntry.swift`

Plain `Codable` + `Identifiable` struct. No logic.

#### `TranscriptionStore.swift`

Singleton (`TranscriptionStore.shared`) managing the JSON file.

**In-memory model:** On init, the store loads `history.json` from disk into a private `[TranscriptionEntry]` array, purging entries older than 7 days during load. All subsequent reads serve this in-memory array — the file is never read again until the next app launch. Writes (append, delete, clear) update the in-memory array and then write the full array to disk synchronously.

Public API:
- `var entries: [TranscriptionEntry]` — in-memory array, newest-first, always within the last 7 days
- `append(_ entry: TranscriptionEntry)` — adds entry to front of in-memory array, purges old entries, saves to disk
- `delete(id: UUID)` — removes matching entry from in-memory array, saves to disk
- `clear()` — empties in-memory array, saves to disk (empty JSON array)

Error handling:
- If `Application Support/VoiceInput/` directory cannot be created, log the error and skip saving (history is a convenience feature, not critical path)
- If `history.json` is corrupt or undecodable on load, reset in-memory array to `[]` and overwrite the file silently

#### `HistoryWindow.swift`

`NSPanel` (~600×500), `isReleasedWhenClosed = false`. Window is `nonactivating` so opening it does not steal focus from the app the user is typing in. Use `styleMask: [.titled, .closable]`, consistent with `SettingsWindow`.

**On open:** reload data from `TranscriptionStore.shared.entries`, reset search field to empty, scroll table to top.

**On close:** no special teardown needed; state resets on next open (search field cleared, scroll position reset to top).

Layout from top to bottom:
1. **`NSSearchField`** — live-filters the table as the user types. Filtering is a **case-insensitive substring match on `TranscriptionEntry.text` only** (not on the formatted date string). Partial word matching is supported (e.g. "hel" matches "hello").
2. **`NSScrollView` + `NSTableView`** — one row per entry:
   - Transcription text (word-wrapping for long entries)
   - Timestamp: "Today 2:34 PM" if same calendar day, otherwise "Apr 10, 9:15 AM"
   - SF Symbol badge `wand.and.stars` (small, tinted) if `wasRefined == true`
3. **Bottom toolbar** — "Clear All" button (left-aligned) + a `statusLabel` (right-aligned, hidden by default) for transient feedback messages
4. **Empty state:** when the filtered or unfiltered list is empty, display a centered label:
   - No entries at all: *"No transcription history yet. Hold Fn and speak to get started."*
   - Search yields no results: *"No results for '\(query)'"*

**Row interactions:**
- **Double-click** — copies text to clipboard; shows "Copied!" in the status label for 1.5 seconds
- **Right-click context menu:**
  - "Copy" — copies text to clipboard; shows "Copied!" in status label for 1.5 seconds
  - "Re-inject" — see Re-inject section below
  - "Delete" — calls `TranscriptionStore.shared.delete(id:)`, reloads table

**Clear All button:** shows `NSAlert` confirmation ("This will permanently delete all transcription history. Are you sure?") before calling `TranscriptionStore.shared.clear()` and reloading the table.

**Re-inject behavior:**
Before calling `TextInjector.inject()`, the History window must not be the key window — otherwise the paste will target the History window itself. The sequence is:
1. Record the entry text
2. Call `self.orderOut(nil)` to hide the window
3. After a short delay (~150ms, enough for the previously focused app to regain key status), call `TextInjector.inject(text)`

This mirrors the existing pattern in `AppDelegate.finishTranscription()` which also uses a `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` before injecting.

### Modified Files

#### `AppDelegate.swift`

**1. New property:**
```swift
private lazy var historyWindow = HistoryWindow()
```

**2. `setupStatusBar()`** — add "History..." menu item:
```
Enabled
──────
Language ▶
LLM Refinement ▶
──────
History...        ← new
──────
Quit VoiceInput
```
```swift
let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "")
historyItem.target = self
menu.addItem(historyItem)
```

**3. New action:**
```swift
@objc private func openHistory() {
    historyWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

**4. `finishTranscription()`** — append to store at all three terminal branches:

*Branch A — LLM refinement succeeded and changed the text (`wasRefined = true`):*
```swift
// after: self.overlayPanel.dismiss() / self.textInjector.inject(finalText)
TranscriptionStore.shared.append(
    TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: true)
)
```

*Branch B — LLM refinement succeeded but did not change the text (`wasRefined = false`):*
```swift
TranscriptionStore.shared.append(
    TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
)
```

*Branch C — LLM refinement failed; original text is injected (`wasRefined = false`):*
```swift
TranscriptionStore.shared.append(
    TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: false)
)
```

*Branch D — LLM disabled; raw transcription injected (`wasRefined = false`):*
```swift
TranscriptionStore.shared.append(
    TranscriptionEntry(id: UUID(), text: text, date: Date(), wasRefined: false)
)
```

All four appends go inside or immediately after the relevant injection call, within the same closure/scope where `lastPartialResult = ""` is reset.

## Data Flow

```
Fn held → SpeechEngine → onFinalResult / finishTranscription()
    → LLMRefiner (optional)
    → TextInjector.inject(finalText)        ← existing
    → TranscriptionStore.shared.append()    ← new (all branches)
    → (future) NSPasteboard write           ← Clipy integration hook
```

## Out of Scope

- Export / backup of history
- Editing past transcriptions
- Storing the original pre-refinement text alongside the refined text
- Syncing history across machines
- Clipy integration (future follow-up)
