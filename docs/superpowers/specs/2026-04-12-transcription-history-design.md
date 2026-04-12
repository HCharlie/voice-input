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
    let text: String
    let date: Date
    var wasRefined: Bool  // true if LLM refinement changed the original transcription
}
```

### Storage

- **File:** `~/Library/Application Support/VoiceInput/history.json`
- **Format:** JSON array of `TranscriptionEntry` objects
- **Retention:** 7 days rolling; entries older than 7 days are purged on load

## Architecture

### New Files

#### `TranscriptionStore.swift`

Singleton (`TranscriptionStore.shared`) managing the JSON file.

Responsibilities:
- `append(_ entry: TranscriptionEntry)` — adds entry, saves to disk, purges old entries
- `entries: [TranscriptionEntry]` — all entries from the last 7 days, newest-first
- `delete(id: UUID)` — removes a single entry and saves
- `clear()` — removes all entries and saves
- Purge logic runs on every load and every append

#### `TranscriptionEntry.swift`

Plain `Codable` + `Identifiable` struct. No logic.

#### `HistoryWindow.swift`

`NSPanel` (~600×500), `isReleasedWhenClosed = false`, consistent with `SettingsWindow`.

Layout:
1. **`NSSearchField`** at top — live-filters the table as the user types
2. **`NSScrollView` + `NSTableView`** — one row per entry:
   - Transcription text (word-wrapping for long entries)
   - Timestamp formatted as "Today 2:34 PM" or "Apr 10, 9:15 AM"
   - "✨" badge if `wasRefined == true`
3. **Bottom toolbar** — "Clear All" button (left-aligned)

Row interactions:
- **Double-click** — copies text to clipboard
- **Right-click context menu:**
  - "Copy" — copies text to clipboard
  - "Re-inject" — calls `TextInjector` to type text into focused app
  - "Delete" — removes entry from store and reloads table

### Modified Files

#### `AppDelegate.swift`

1. **`finishTranscription()`** — after `finalText` is determined in both the LLM-refined and non-refined paths, append to store:
   ```swift
   TranscriptionStore.shared.append(
       TranscriptionEntry(id: UUID(), text: finalText, date: Date(), wasRefined: wasRefined)
   )
   ```

2. **`setupStatusBar()`** — add "History..." menu item above the final separator:
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
   Action calls `openHistory()` which does `historyWindow.makeKeyAndOrderFront(nil)` + `NSApp.activate(ignoringOtherApps: true)`.

3. Add `private lazy var historyWindow = HistoryWindow()` property.

## Data Flow

```
Fn held → SpeechEngine → onFinalResult / finishTranscription()
    → LLMRefiner (optional)
    → TextInjector.inject(finalText)        ← existing
    → TranscriptionStore.shared.append()    ← new
    → (future) NSPasteboard write           ← Clipy integration hook
```

## Error Handling

- If the `Application Support` directory cannot be created, log the error and silently skip saving (history is a convenience feature, not critical)
- If the JSON file is corrupt on load, reset to an empty array and overwrite
- Re-inject via `TextInjector` uses the existing injection path — no special error handling needed

## Out of Scope

- Export / backup of history
- Editing past transcriptions
- Syncing history across machines
- Clipy integration (future follow-up)
