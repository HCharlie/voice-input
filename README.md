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

- Press **Fn** to start recording
- Speak your text
- Release **Fn** to stop — the transcribed text is typed into the focused text field

You can change the recognition language from the menu bar icon (click the mic icon → Language).

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
