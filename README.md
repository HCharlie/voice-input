# VoiceInput

A macOS menu-bar app for hands-free text input. Hold the **Fn** key, speak, and your words are transcribed in real time and typed directly into whatever text field is focused — any app, any text field. Powered entirely by Apple's on-device Speech Recognition framework, so nothing leaves your Mac.



## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (for `swift build`)

## Installation

1. Clone and install:

```bash
git clone https://github.com/HCharlie/voice-input.git
cd voice-input
make install
```

2. Launch:

```bash
/Applications/VoiceInput.app/Contents/MacOS/VoiceInput &
```

3. Grant permissions when prompted:
   - **Accessibility** — System Settings → Privacy & Security → Accessibility → enable VoiceInput
   - **Microphone** — prompted automatically on first recording
   - **Speech Recognition** — prompted automatically on first recording

4. Disable the emoji picker for the Fn key:
   - System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**

## Usage

### Recording

- **Hold Fn** to start recording
- Speak your text
- **Release Fn** to stop — the transcribed text is typed into the focused text field

### Language switching

**Double-tap Fn** (two quick taps, each under 300ms) to cycle through your configured languages. A brief overlay confirms the switch.

To configure which languages are in the cycle:

1. Click the mic icon in the menu bar
2. Go to **Language**
3. In the **"Double-tap Fn cycles:"** section at the bottom, check the languages you want to cycle through

The active language (used for recording) is shown with a checkmark in the top section of the Language menu. The cycle defaults to English (US) and 中文 (简体) on first launch.

> **Note:** The language selector is a preference — the app always recognises English and Chinese simultaneously and picks the best match automatically. Switching language adjusts the UI and your saved preference.

### LLM refinement (optional)

Click the mic icon → **LLM Refinement → Settings** to configure an OpenAI-compatible API key. When enabled, transcriptions are polished by the LLM before being typed.

## Build Commands

```bash
make build   # build the .app bundle
make run     # build, install to /Applications, and launch
make install # build and copy to /Applications
make clean   # remove build artifacts
```

## Forked From

This is a fork of [yetone/voice-input-dist](https://github.com/yetone/voice-input-dist). The original source code lives at [yetone/voice-input-src](https://github.com/yetone/voice-input-src).

## License

See the [source repository](https://github.com/yetone/voice-input-src) for license details.
