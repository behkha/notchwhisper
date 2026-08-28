# NotchWhisper

A free, fully-local voice-to-text app for macOS that shows its status in the
**MacBook notch** and types your speech straight into whatever text field is
focused anywhere on your Mac. No cloud, no API keys, no subscriptions — the
speech recognition runs on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
(Core ML Whisper), and models download on demand from Hugging Face.

This is the free, open alternative to apps like *Spokenly* whose notch display
is locked behind a paid plan.

## Features

- **Notch display** — a FaceTime-style pill lives in the camera notch (or the
  menu-bar band on non-notched Macs): idle / recording waveform / transcribing
  spinner / done / error, plus a live download-percentage badge.
- **Hold-to-talk** — press and hold a global hotkey (default **Right ⌥**) to
  record, release to transcribe. Works while any other app is focused.
- **Auto-type anywhere** — the transcript is inserted into the currently
  focused text field via the Accessibility API (with a keystroke fallback), so
  it lands in Notes, Messages, your editor, a browser input — anywhere.
- **Local models from Hugging Face** — pick from `tiny` → `large-v3` and
  download with one click inside the app. Models are cached on disk and never
  leave your machine.
- **Menu-bar app** — no Dock icon; everything lives in the status bar + notch.
- Configurable language, transcribe-vs-translate, newline-after-text, haptics,
  launch-at-login, and a re-recordable hotkey.

## Requirements

- macOS 14+ (tested on macOS 26 / Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- Microphone permission (prompted on first record)
- Accessibility permission (for auto-typing into other apps)

## Build & run

```bash
cd ~/Programming/NotchWhisper
./build.sh
open build/NotchWhisper.app
```

`build.sh` resolves WhisperKit via SwiftPM, compiles a release executable,
packages it as an ad-hoc-signed `.app` in `build/`, and strips the quarantine
flag so it launches without Gatekeeper complaints.

> Because the app is ad-hoc signed (no paid Developer ID), macOS may ask you to
> allow it the first time. Grant Microphone + Accessibility in System Settings
> → Privacy & Security when prompted.

## First launch

1. The app appears as a waveform icon in the menu bar. The notch pill shows
   **"Loading model…"** while the default (`base`) Whisper model downloads from
   Hugging Face, then **"Hold ⌥ to talk"**.
2. Open **System Settings → Privacy & Security → Accessibility** and enable
   NotchWhisper so it can type into other apps.
3. Hold the hotkey (Right ⌥), speak, release. The text appears wherever your
   cursor is.

## Settings

Click the menu-bar icon to open settings:

- **Model** — choose the active model and download others. Larger = more
  accurate but slower and bigger downloads.
- **Hotkey** — re-record the hold-to-talk key (all modifiers captured).
- **Behavior** — toggle auto-type, newline after text, haptics, language
  (auto-detect by default; supports English, Persian, Spanish, …), and
  transcribe vs. translate-to-English.
- **Appearance** — voice-reactive notch glow toggle, plus the **notch
  visualizer** picker: five styles faithfully ported from LiveKit's Agents-UI
  components (livekit/components-js `packages/shadcn`) — **Bar** (default,
  five rounded bars), **Wave** (bell-attenuated oscilloscope sine, LiveKit
  cyan), **Radial** (24 dots on a ring that grow outward with volume),
  **Grid** (5×5 pulsing cells), and **Aura** (organic glowing energy field).
  LiveKit's design language is preserved: elements sit at 10% opacity and a
  state-driven highlight sequencer lights them; volume drives size only while
  recording (= LiveKit "speaking"), transcribing plays the "thinking"
  patterns. Each has a live animated preview in Settings; the choice persists
  in UserDefaults (`visualizerStyle`).
- **Permissions** — Accessibility status + optional Hugging Face token (only
  needed for gated models; stored in your login Keychain).

## Architecture

```
Sources/NotchWhisper/
  main.swift            entry point (LSUIElement / accessory app)
  AppState.swift        observable state shared by UI + logic
  Settings.swift        UserDefaults-backed preferences
  NotchWindow.swift     borderless always-on-top panel in the notch
  NotchView.swift       SwiftUI pill UI (waveform, spinner, badges)
  Visualizers.swift     5 LiveKit-style audio visualizers + settings preview
  AudioRecorder.swift   AVAudioEngine → 16 kHz mono + live RMS levels
  Transcriber.swift     WhisperKit wrapper (load + download + transcribe)
  AutoTyper.swift       Accessibility insert + CGEvent keystroke fallback
  HotkeyMonitor.swift   Carbon global hotkey (press/release)
  MenuBar.swift         status item + popover settings UI
  Keychain.swift        HF token storage
  Models.swift          Whisper model catalog (Hugging Face ids)
  AppDelegate.swift     wires everything; record→transcribe→type flow
```

The microphone audio is resampled to 16 kHz mono (Whisper's input rate) in
`AudioRecorder`, transcribed by WhisperKit, and the resulting text is typed
into the focused field by `AutoTyper`.

## Background agent + launch at login

NotchWhisper is a background agent (`LSUIElement`): no Dock icon, no window at
launch. It lives in the menu bar (mic icon) and the notch. The main window
opens only from the menu bar → "Open NotchWhisper" (or on first run, when no
model is downloaded yet).

- Launch at login uses `SMAppService.mainApp` (System Settings → General →
  Login Items & Extensions). Default ON; toggle in Settings → General.
  `register()`/`unregister()` are idempotent — do NOT pre-check
  `.notFound` status before registering (it wrongly skips first-time
  registration for freshly-built bundles).
- After rebuilding, if the login item stops working, re-register by relaunching
  the app (it reconciles on every startup).

Dev/test hooks (all non-activating, never steal focus):
- `--wave-preview` — shows the notch pill with a simulated voice waveform for
  90s (for design evaluation/screenshots).
- `/tmp/nw_type_trigger` — file whose contents get typed into the frontmost
  app 2s after launch; report → `/tmp/nw_typeresult.txt`.

## Typing text (AutoTyper)

Text is inserted by posting synthetic keyboard events that carry Unicode
strings — what a real keyboard does. This is layout-independent, case-correct,
and works in terminals (Terminal.app, iTerm, Warp), which ignore AX value
writes on their content view. Multi-line text sends real Return keypresses
between lines. The AX value-set path was deliberately removed: it "succeeds"
silently against Terminal's text area while sending nothing to the pty.

Dev/test hook: create `/tmp/nw_type_trigger` containing text, then launch the
app (or `open -g` it). It types the text into the frontmost app after 2 s,
writes a diagnostic report to `/tmp/nw_typeresult.txt`, and quits. The
production hotkey path (record → transcribe → type) shares this exact code.

## Notes

- The notch pill is positioned on the notched (built-in) display when more than
  one screen is attached.
- WhisperKit downloads model weights once and caches them under
  `~/Library/Application Support/NotchWhisper/Models`.
- This is a script-compiled SwiftPM app (no `.xcodeproj`). Re-run `./build.sh`
  after any code change.

## Permissions & code signing

macOS binds TCC grants (Accessibility, Input Monitoring, Microphone) to the
app's **code signature**. Ad-hoc signing (`codesign -`) mints a new CDHash on
every build, which silently orphans the grant: the System Settings toggle stays
ON for the stale record, but the new binary is denied and prompts again on
launch.

`NotchWhisper.app` avoids this by signing with a stable self-signed identity:

- `./setup_signing_identity.sh` — one-time setup; creates the **NotchWhisper
  Dev** code-signing certificate in the login keychain (valid 10 years).
- `./build.sh` signs with it automatically and falls back to ad-hoc with a
  loud warning if the identity is missing.

If the permission prompt ever reappears after a rebuild:

1. `security find-identity -v -p codesigning` — confirm `NotchWhisper Dev` is
   listed and valid. If not, re-run `./setup_signing_identity.sh`.
2. `codesign -d -r- build/NotchWhisper.app` — the designated requirement must
   reference `certificate root = H"f402f80e..."` (the NotchWhisper Dev cert),
   not plain ad-hoc.
3. If the requirement is right but access is still denied, clear the stale
   record once and re-grant: `tccutil reset Accessibility
   com.behkha.notchwhisper` (also `ListenEvent`, `PostEvent`, `Microphone`),
   then relaunch.
