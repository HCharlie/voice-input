# Changelog

All notable changes to VoiceInput are documented here.

## [Unreleased]

## [2026-04-20]

### Added
- **Send Enter after dictation** — new menu bar toggle that automatically presses Return after each transcription is pasted. Useful for chat and messaging apps. Off by default; setting persists across restarts.

## [2026-04-18]

### Added
- **Double-tap Fn to cycle languages** — two quick taps cycles through a configurable set of languages with a brief overlay confirming the active one. Defaults to English (US) and 中文 (简体).
- **Language cycle configuration** — Language menu now has a "Double-tap Fn cycles:" section with per-language checkboxes. Languages in the cycle are pre-warmed in the background for instant, zero-latency switching.

### Fixed
- Overlay now stays visible during mid-hold recognition errors instead of disappearing.
- Stale `finalResultTimer` from a previous recording is cancelled when a new recording starts.
- Speech callbacks are now dispatched to the main thread; stale results from cancelled sessions are discarded.

## [2026-04-12]

### Added
- **Transcription history** — History window (menu bar → History…) shows all past dictations with timestamps. Supports search, copy to clipboard, re-inject into the focused field, and clear all.
- Transcriptions are persisted to disk as JSON and survive app restarts.
