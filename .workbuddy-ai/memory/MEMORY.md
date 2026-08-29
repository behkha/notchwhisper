# NotchWhisper — project notes

Free, fully-local voice-to-text macOS app. Swift + SwiftPM, single executable
(`NotchWhisper`) plus `TranscribeTest`/`LiveRepro` helper targets. Speech recognition
on-device via WhisperKit (Core ML Whisper); models download from Hugging Face.

- App type: accessory/`LSUIElement` (no Dock icon). Menu-bar mic item + notch pill;
  on-demand main window (Home, Transcripts, Dictionary, Models) + Settings (⌘,).
- Default hotkey: Right ⌥ (hold-to-talk). Live dictation toggle = press-on/press-off.
- Features: notch display, hold-to-talk, live dictation, auto-type (Accessibility +
  keystroke fallback), local Whisper models w/ live HF search, Local LLM
  post-processing (OpenAI-compatible), Custom Dictionary, Transcript History, 6 themes,
  5 LiveKit-style visualizers.
- Build: `./build.sh`. Signing: `./setup_signing_identity.sh` creates "NotchWhisper Dev"
  self-signed identity so TCC (Accessibility/Input Monitoring/Mic) grants survive rebuilds;
  falls back to ad-hoc otherwise.
- Bundle id: com.behkha.notchwhisper. Support dir: ~/Library/Application Support/NotchWhisper/
- No LICENSE file yet (default all-rights-reserved as of 2026-08-29).
- "Behavior" prefs (autoType/newline/language/task/haptics) live in Settings.swift but are
  not surfaced in the Settings UI.
