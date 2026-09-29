# NotchWhisper

> A free, local voice-to-text app for macOS that lives in the **MacBook notch** and types your speech straight into whatever text field is focused — no subscriptions. Transcription never leaves your Mac; the optional AI pass goes to whichever connection you choose, local or hosted, and the app tells you which.

NotchWhisper runs speech recognition **on your Mac** with [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML Whisper), NVIDIA's Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio), Qwen3-ASR through llama.cpp, or the recognizer built into macOS 26. Models download on demand from Hugging Face and never leave your machine. Hold a hotkey, speak, and the words appear wherever your cursor is — Notes, Messages, your editor, a browser input, anywhere.

It's the open, local alternative to apps whose notch display is locked behind a paid plan.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10-F54A2A)](https://www.swift.org/)
[![100% On-device](https://img.shields.io/badge/100%25%20On--Device-2ecc71)](https://github.com/argmaxinc/WhisperKit)
[![Local LLM ready](https://img.shields.io/badge/Local%20LLM%20ready-8e44ad)](https://github.com/ollama/ollama)

---

## Quick start

```bash
# Prerequisite: Xcode Command Line Tools (provides swiftc)
xcode-select --install

# Optional but recommended: a stable code-signing identity so macOS
# permissions survive rebuilds. Skip it and the app falls back to ad-hoc signing.
./setup_signing_identity.sh

# Build the .app (resolves WhisperKit, compiles, packages, signs)
./build.sh

# Launch
open build/NotchWhisper.app
```

On first launch the default `base` model downloads from Hugging Face (you'll see a live percentage in the notch), then the app is ready: **hold `Right ⌥`, speak, release.**

---

## Features

- **Notch display** — a FaceTime-style pill lives in the camera notch (or the menu-bar band on non-notched Macs) showing idle → recording waveform → transcribing → improving → done → error, plus a live download-percentage badge.
- **Hold-to-talk** — press and hold a global hotkey (default **Right `⌥`**) to record, release to transcribe. Works while any other app is focused.
- **Live dictation** — flip it on in Settings → General and the hotkey becomes press-on / press-off: speak and the words are typed into the focused field **in real time**, with the live transcript shown in the notch.
- **File transcription** — the **Upload** page takes any audio or video file (drop it in or pick it), decodes it locally, and transcribes the whole thing with a progress bar you can cancel. The text is editable in place, copyable, saveable as `.txt`, and saved to history like any other transcript.
- **Auto-type anywhere** — the transcript is inserted into the focused field via the Accessibility API (with a keystroke fallback) so it lands in any app.
- **Model manager** — the **Models** page is a full manager, not just a picker: it shows the active engine and its health, everything installed, what's recommended *for your Mac*, and a searchable catalog that spans the built-in models and [Hugging Face](https://huggingface.co/models). Installs are queued, resumable, pausable and verified before a model is ever activated; models can be benchmarked and compared on your own audio, tested in a playground, imported from disk, pinned to a revision, and removed with a storage view that shows exactly what each one costs.
- **Local LLM post-processing** — optionally clean up, format, rewrite, summarize, or structure your transcript with a language model running **on your Mac** (Ollama, LM Studio, Unsloth, or any OpenAI-compatible server). Your text stays local.
- **Context-aware modes** — a mode can read the text you have selected and your clipboard, so "reply to this" or "summarize the above" has something to work with. Off per mode until you turn it on; the editor says when that text would leave the Mac.
- **Edit a selection by voice** — an **Edit selection** shortcut: highlight text in any app, hold the key, say "make it shorter" or "translate to German", and the selection is replaced with the result.
- **Meetings** — record a call or a room (microphone plus, with your permission, the Mac's own audio) to a crash-safe file on disk, get a timestamped transcript you can click to replay, minutes written by your AI connection, Markdown/text/JSON/WAV export, and a one-click "delete audio, keep transcript".
- **Microphone switcher** — pick the input NotchWhisper records from in Settings → Microphone or straight from the menu bar, without touching the system input other apps use. A test meter shows the mic hears you; a picked mic that's unplugged falls back to Automatic, and a capture whose mic disappears mid-sentence moves to the next one and keeps what it already heard.
- **Works with the lid closed** — in clamshell mode (MacBook shut, external display over HDMI or USB-C) the built-in mic is disconnected in hardware, so NotchWhisper records from another microphone — AirPods, a USB mic or webcam, an audio interface, your iPhone — on its own, and the notch pill appears on the external display. With no other mic connected it says so instead of recording silence.
- **Silence gate** — a recording with no speech in it is discarded instead of handed to Whisper, which invents "Thank you." on silence; silence is trimmed before decoding; accidental taps are ignored; a live session can end itself after a quiet spell. All tunable in Settings → Voice detection.
- **Sounds and notifications** — a tick when the mic opens, a pop when it closes, a low note on failure; a system notification when a model finishes installing, a download fails, or an AI pass falls back to your original text while the app is in the background.
- **Custom dictionary** — teach the model words it keeps getting wrong, and auto-correct heard phrases ("cloud code" → "Claude Code"). Entries bias recognition *and* fix the typed output. Editable in the UI or as a plain-text file.
- **Transcript history** — every dictation is saved (raw, corrected, which dictionary fixes fired, and which LLM mode) so you can search, copy, and revisit past transcripts.
- **Six accent themes** — Ember (default), Ocean, Violet, Forest, Rose, Aqua. Recolors the whole app, the notch glow, and the Wave/Aura visualizers.
- **Five notch visualizers** — ported from LiveKit's Agents-UI: Bar, Wave, Radial, Grid, Aura. Aura is the actual Unicorn Studio turbulence shader, ported to Metal and compiled at runtime (Polyform Non-Resale License 1.0.0, © UNCRN LLC — see `AuraShader.swift`).
- **Menu-bar app** — no Dock icon; everything lives in the status bar + notch, with an on-demand main window (Home, Upload, Transcripts, Dictionary, Models).

---

## Using NotchWhisper

**Hold-to-talk (default)**
1. A microphone icon appears in the menu bar. The notch pill shows **"Loading model…"** while the default (`base`) model downloads, then **"Hold `⌥` to talk"**.
2. Open **System Settings → Privacy & Security → Accessibility** and enable NotchWhisper so it can type into other apps.
3. Hold the hotkey (Right `⌥`), speak, release. The text appears wherever your cursor is.

**Live dictation**
In **Settings → General**, enable *Live dictation*. The hotkey switches to a toggle: press once to start a continuous session, speak, press again to stop. Words are typed as you talk; the notch shows the live transcript.

**Transcribing a file**
Open the main window → **Upload**, then drop in a recording (or click *Choose file…*). MP3, WAV, M4A, AAC, FLAC, AIFF, CAF, MP4 and MOV all work, at any length — the audio is decoded to 16 kHz mono on your Mac and run through the same engine, dictionary bias and correction pass as dictation. Long files show progress over the clip and can be cancelled mid-run. Nothing is auto-typed; you get the text on the page to edit, copy, or save.

**Editing a selection by voice**
In **Settings → Shortcuts**, add a shortcut from the **Edit selection** starter (or set any shortcut's behaviour to *Edit selection*). Highlight text in any app, hold the key, say what to change — "make this formal", "fix the grammar", "turn it into a list" — and release. The instruction is transcribed, sent with the selected text to your active AI connection, and the reply replaces the selection. Apps that don't expose their selection to Accessibility get a ⌘C round trip; your clipboard is put back afterwards. Needs an AI connection.

**Recording a meeting**
Open the main window → **Meetings**. Read the one-time note about consent, then **Start recording**. With *Include the Mac's audio* on, macOS asks for the Screen Recording permission the first time — only audio is ever read; off records just your microphone. Audio streams to a two-channel 16 kHz WAV under `~/Library/Application Support/NotchWhisper/Meetings/` whose header is rewritten every ten seconds, so a crash still leaves a playable file (it shows as *Interrupted* and can be transcribed). Stopping transcribes the recording in 30-second windows, skipping the silent ones, with timestamps you can click to replay from that point. **Write minutes** runs the built-in *Meeting Minutes* mode (or any mode of yours) over the transcript; the first time your active connection is a hosted one you're asked before the transcript leaves the Mac. Export as Markdown, plain text, JSON or WAV, or delete the audio and keep the transcript.

**Choosing a microphone**
Settings → **Microphone** (or the *Microphone* row in the menu-bar panel) lists every connected input. **Automatic** follows System Settings → Sound; picking a mic makes NotchWhisper use it whenever it's connected — only NotchWhisper's input changes, never the system one. *Test* opens that mic and shows a level bar. Dictation, meetings and the Models lab all use the same choice. If the picked mic is unplugged, Automatic takes over and the notch names the mic in use; if a mic disappears mid-recording, the recording moves to the next one and keeps what was already said.

**With the lid closed (clamshell mode)**
A MacBook with a T2 chip or Apple silicon disconnects its built-in microphone in hardware whenever the lid is closed — no app can record from it then, so there is no software way around it. What NotchWhisper does instead:
- It reads the lid state and, while the lid is closed, never records from the built-in mic. Automatic picks the best other microphone: the headset you're listening on, then wired (USB, the headphone jack), an audio interface, Bluetooth, a display's mic, and last your iPhone. A loopback device like BlackHole is never picked automatically.
- The notch pill shows at the top centre of the external display, and names the mic in use when it isn't your usual one.
- With no other microphone connected, a dictation stops right away with *"Lid closed, so the built-in mic is off…"* rather than recording silence — Settings → Microphone says the same before you try.

To dictate with the lid closed, connect any of: AirPods or another Bluetooth headset, a USB microphone or webcam, a wired headset, or your iPhone (macOS 13+, iPhone on iOS 16+, nearby and signed in to the same Apple Account — it shows up as a microphone in the list). HDMI carries no microphone, so the monitor itself can't provide one unless it has a USB/Thunderbolt mic of its own.

**Changing the hotkey**
In **Settings → Hotkey**, click the key cap and press what you want. Three shapes are accepted:
- a bare modifier — tap `⌥` (left or right are distinct keys) and release;
- a modifier combination — hold `⌘`, tap `⌥`, release both → `⌘⌥`;
- a regular key with modifiers — hold `⌃⌥` and press Space → `⌃⌥Space`.

Escape cancels the recording; the ↺ button restores Right `⌥`. Left and right modifiers are told apart, so Right `⌥` stays free of the Option character-entry layer on the left key.

**First run details**
- The main window opens automatically the first time (when no model is downloaded yet). Afterwards the app stays invisible until you open it from the menu bar → **Open NotchWhisper**.
- WhisperKit caches models under `~/Library/Application Support/NotchWhisper/Models`.

---

## Models

NotchWhisper ships with the full `argmaxinc/whisperkit-coreml` catalog (27 variants). Pick one in **Settings → Model** or the **Models** page:

| Tier | Examples | Size | Best for |
| --- | --- | --- | --- |
| Fast | `tiny`, `tiny.en` | ~75 MB | Instant, rough text |
| Balanced | `base`, `base.en`, `small` | ~140–470 MB | Everyday multilingual dictation (default: **`base`**) |
| Accurate | `medium`, `distil-large-v3` | ~750 MB – 1.5 GB | High accuracy, 16 GB+ Macs |
| Best | `large-v3`, `large-v3 turbo` | ~947 MB – 3.1 GB | Highest accuracy; turbo ≈ 8× speed |

Larger models are more accurate but slower and heavier to download.

### The Models page

Everything about models lives on one page; Settings keeps only the behavioural
choices (which model is active, whether to pick one automatically, when to load it).

- **Active model** — what's running right now, its health, and what it costs in disk and memory.
- **Installed** — one row per model with a single primary action (`Use` / `Repair` / `Resume`), and the rest behind `•••`.
- **Recommended for your Mac** — scored against your actual hardware, your languages, your own benchmark results and your power state. Every recommendation lists the reasons that earned it.
- **Discover** — the built-in catalog plus a live Hugging Face search, with combinable filters (language, size, performance, format, runtime, source, compatibility). Only formats a shipped runtime can actually load are offered; anything else is explained rather than hidden.
- **Storage** — per-model usage, remove unused models, clear interrupted downloads, and move the model directory (copy → verify → delete, so an interrupted move never loses anything).

Accuracy and speed figures come from the model cards and are labelled as
published approximations. Anything NotchWhisper hasn't measured says
**Not benchmarked** rather than inventing a score — run the built-in benchmark
and it reports real numbers from your Mac (processing time, real-time factor,
peak memory, CPU, first-result latency, and word error rate if you supply a
reference transcript). Benchmark audio and results never leave the machine.

Downloads run through a single queue: one transfer at a time, resumable, with
byte-accurate progress, pause/cancel/retry, and a verification pass that must
succeed before a model is marked installed or made active.

### Qwen3-ASR (llama.cpp)

Apple Silicon only. The **Models** page also offers **Qwen3-ASR** — Qwen's multilingual speech model — run on the Metal GPU through a bundled build of [llama.cpp](https://github.com/ggml-org/llama.cpp) (`mtmd`). It's strong on accents, code-switching and noisy audio, and takes a short context prompt (dictionary terms as hotwords, an optional language hint).

| Model | Download | RAM |
| --- | --- | --- |
| Qwen3-ASR 0.6B (Q8) | ~0.9 GB | 8 GB+ |
| Qwen3-ASR 1.7B (Q8) | ~2.5 GB | 16 GB+ |
| Qwen3-ASR 1.7B (BF16) | ~4.7 GB | 24 GB+ |

GGUF weights download on demand from `ggml-org/Qwen3-ASR-*-GGUF` into `~/Library/Application Support/NotchWhisper/Models/llama/`. **Hold-to-talk only** — live dictation needs WhisperKit, Parakeet or Apple Speech (Qwen3-ASR has no streaming/timestamp API). The dictionary-correction and local-LLM passes run on its output unchanged.

The prebuilt llama.cpp libraries are vendored in `vendor/llama/` (pinned to a llama.cpp release; regenerate or bump with `scripts/fetch_llama.sh`). `build.sh` copies them into `NotchWhisper.app/Contents/Frameworks` and the ad-hoc/self-signed `--deep` signature covers them. For a **notarized** release each `vendor/llama` dylib must be signed with your Developer ID, the hardened runtime, and a secure timestamp before notarization.

### Parakeet (FluidAudio)

Apple Silicon only. [Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) is NVIDIA's FastConformer + token-and-duration transducer — a different architecture from Whisper, so its Core ML bundles (`Preprocessor`, `Encoder`, `Decoder`, `JointDecision`) are opened by [FluidAudio](https://github.com/FluidInference/FluidAudio) rather than WhisperKit. It runs on the Neural Engine at roughly 100× real time, fast enough to re-decode the live window on every tick, so it drives **live dictation** as well as hold-to-talk, uploads and meetings.

| Model | Download | Languages |
| --- | --- | --- |
| Parakeet Ultra | ~632 MB | 25 European languages — the most accurate build |
| Parakeet v3 | ~483 MB | 25 European languages |
| Parakeet v2 (English) | ~464 MB | English only, best recall on rare words |

Weights come from FluidInference's `*-coreml` repositories into `~/Library/Application Support/NotchWhisper/Models/fluidaudio/`; searching the Hub for one of those repositories installs the same catalog model. **Import** also accepts a Parakeet folder from disk. Parakeet takes no prompt, so dictionary terms reach its text through the correction pass rather than as a bias.

### Apple Speech (macOS 26+)

On macOS 26 and later, **Apple Speech** uses the recognizer built into the system (`SpeechAnalyzer` / `SpeechTranscriber`) — nothing to download for languages macOS already has; others are fetched and managed by macOS itself. It can't detect the language on its own, so it follows the language setting (or the Mac's language when that's auto). It supports live dictation, and dictionary terms are passed to it as contextual strings.

---

## Local LLM post-processing

> Optional. Off by default. Requires a local OpenAI-compatible server (e.g. [Ollama](https://ollama.com), [LM Studio](https://lmstudio.ai), Unsloth) — nothing leaves your machine.

After a transcript is produced, NotchWhisper can send it to a model for a
processing pass before insertion. Two things set that up, both on the **AI**
page of the main window:

| Page | What it holds |
| --- | --- |
| **AI → Connections** | *Where* text is sent — any OpenAI-compatible endpoint (Ollama, LM Studio, llama.cpp, a hosted provider). Address, model name, and an optional API key stored in your login Keychain. One connection is active at a time; an app profile can pin a different one. |
| **AI → Modes** | *What* is done to it. A mode is a name, an icon, instructions in your own words, and how much latitude the model gets (Precise / Balanced / Creative). Modes that produce ONE document (a summary, a checklist) can say so, and long dictations are merged by a second pass instead of concatenated. |

**Settings → Text processing** carries the master switch and the mode that runs
by default. Picking **No processing** inserts the transcript exactly as
dictated — no AI, nothing leaves the Mac.

**Modes are yours.** There are no fixed built-in modes: six are installed on
first launch as ordinary modes you can read, edit, rename, duplicate or delete.

| Mode | What it does |
| --- | --- |
| Clean Up | Fix filler words, punctuation, and obvious mistakes while keeping your voice. |
| Markdown | Format into clean Markdown without changing the wording. |
| Rewrite | Polish spoken language into natural written prose. |
| Summarize | Condense long dictations into a concise summary. |
| Structured Notes | Organize free-form speech into sensible sections. |
| Extract Actions | Pull tasks, deadlines, and follow-ups into an actionable list. |

Upgrades keep what you had: a mode selected before this change — globally, in an
app profile, or on a shortcut — resolves to the mode that replaced it, and the
old single "Custom" instruction becomes a mode called **My instruction**.

You can switch the mode for the next dictation straight from the menu-bar item,
and override it per app (**Apps**) or per shortcut (**Shortcuts**).

**Guarantees:** the original transcription is *never* replaced by an empty or failed result — if the server errors, you keep your text and are told what happened. Long transcripts are processed in paragraph-sized chunks (never truncated).

---

## Custom dictionary

Found under the **Dictionary** tab in the main window. Two entry types:

- **Term** — a word or phrase the model should recognize (e.g. `Anthropic`). It's sent to Whisper as short biasing context so the model leans toward producing it.
- **Correction** — "when you hear X, write Y" (e.g. `cloud code` → `Claude Code`). Applied as a case-insensitive, whole-word replacement on the typed output.

Entries are also stored as a plain-text file you can edit by hand:

```text
# ~/Library/Application Support/NotchWhisper/dictionary.txt
term: Anthropic
term: Vercel
fix: cloud code -> Claude Code
```

`#` comments and blank lines are ignored. Save the file and the app reloads it automatically (the newer of `dictionary.txt` / `dictionary.json` wins). The UI warns you when a correction looks like it could clobber ordinary words.

---

## Transcript history

Every finished dictation is saved to **Transcripts** (searchable, with copy / copy-raw / delete, and clear-all or clear-matches). Each record keeps the raw engine output, the final corrected text, which dictionary fixes fired, the LLM mode used, and when it happened. The **Home** tab shows live stats (total, today, this week, word count, dictionary fixes, active model) plus your five most recent transcripts. History is capped at 500 entries and stored at `~/Library/Application Support/NotchWhisper/transcripts.json`.

---

## Appearance

**Settings → Appearance** lets you:

- Pick one of **six accent themes** — Ember (default), Ocean, Violet, Forest, Rose, Aqua. The choice recolors the entire app: sidebar, controls, notch glow, and the Wave/Aura visualizers.
- Toggle the **voice-reactive notch glow** (the island's halo breathes and heats up with your voice; off = a calm static glow).
- Choose a **notch visualizer** — Bar (default), Wave, Radial, Grid, Aura — each with a live animated preview.

---

## Settings reference

| Setting | Where | Options | Default |
| --- | --- | --- | --- |
| Live dictation | Dictation | on / off | off |
| Type into the focused app | Dictation | on / off | on |
| New line after each dictation | Dictation | on / off | off |
| Language | Dictation | auto-detect, or any Whisper language | auto-detect |
| Translate to English | Dictation | on / off | off |
| Launch at login | Dictation | on / off | on |
| Microphone | Microphone | Automatic, or any connected input | Automatic |
| Ignore silent recordings | Voice detection | on / off | on |
| Trim silence before transcribing | Voice detection | on / off | on |
| Sensitivity | Voice detection | Low / Normal / High | Normal |
| Minimum press length | Voice detection | Off / 250 ms / 500 ms | 250 ms |
| Stop live dictation after silence | Voice detection | Off / 5 / 10 / 30 / 60 s | Off |
| Theme color | Appearance | Ember / Ocean / Violet / Forest / Rose / Aqua | Ember |
| Voice-reactive glow | Appearance | on / off | on |
| Notch visualizer | Appearance | Bar / Wave / Radial / Grid / Aura | Bar |
| Hold-to-talk hotkey | Hotkey | any key, modifier, or combination | Right `⌥` |
| Active model | Model | tiny → large-v3 (+ turbo/distil/quantized) | `base` |
| Local LLM processing | Text processing | enabled + mode (see above) | off |
| Sounds | Feedback | on / off | on |
| Haptic feedback | Feedback | on / off | on |
| Notifications | Feedback | on / off | on |
| Check for updates automatically | Updates | on / off | on |

---

## How it works

```mermaid
flowchart LR
    A[Microphone] --> B[AudioRecorder<br/>16 kHz mono + live RMS levels]
    B --> C{Interaction}
    C -->|Hold-to-talk| D[Transcriber<br/>WhisperKit]
    C -->|Live dictation| E[LiveTranscriber<br/>bounded sliding-window loop]
    E --> D
    D --> F[Dictionary<br/>biasing + corrections]
    F --> G{Local LLM<br/>enabled?}
    G -->|Yes| H[Local OpenAI-compatible server<br/>Ollama / LM Studio / Unsloth]
    G -->|No| I[Original text]
    H --> I
    I --> J[AutoTyper<br/>Accessibility + keystroke fallback]
    J --> K[Focused text field]
    D --> L[(History)]
    F --> L
    H --> L
```

Microphone audio is resampled to 16 kHz mono (Whisper's input rate) in `AudioRecorder`, transcribed on-device by WhisperKit, optionally polished by a local LLM, and typed into the focused field by `AutoTyper`. Live dictation runs the same recognizer in a bounded sliding-window loop so latency stays flat no matter how long you speak.

### Source layout

```text
Sources/NotchWhisper/
├── main.swift            NSApplication entry point (+ --type-test / --llama-selftest / --file-selftest hooks)
├── AppDelegate.swift     Wires UI, hotkey, and the record → transcribe → type → history flow
├── AppState.swift        Observable state shared by UI + logic
├── Settings.swift        UserDefaults-backed preferences
├── AudioRecorder.swift   AVAudioEngine → 16 kHz mono + live RMS levels, on the chosen mic
├── AudioInputs.swift     Input devices, lid state, which mic to use, routing, mic test meter
├── MicrophoneViews.swift Microphone picker (Settings + menu bar) and the test meter row
├── MicrophoneSelfTest.swift --mic-selftest: choice rules + real routed captures via BlackHole
├── AudioFileImport.swift Decodes a picked audio/video file to 16 kHz mono (AVAudioFile → AVAssetReader)
├── Transcriber.swift     Engine façade: WhisperKit wrapper + routes llama:*, parakeet:* and apple:* ids
├── LlamaASR.swift        llama.cpp / mtmd engine for GGUF Qwen3-ASR (hold-to-talk)
├── LlamaModels.swift     Qwen3-ASR GGUF catalog (llama:* ids)
├── ParakeetASR.swift     FluidAudio engine for Parakeet TDT (download, load, transcribe)
├── ParakeetModels.swift  Parakeet catalog (parakeet:* ids)
├── AppleSpeechASR.swift  SpeechAnalyzer engine + locale asset installs (apple:speech)
├── EngineSegment.swift   Timed text spans from the non-Whisper engines, grouped for live dictation
├── GGUFDownloader.swift  Resumable 2-file GGUF download from Hugging Face
├── LiveTranscriber.swift Continuous type-as-you-speak loop (WhisperKit, Parakeet, Apple Speech)
├── AutoTyper.swift       Accessibility insert + CGEvent keystroke fallback
├── HotkeyMonitor.swift   Global hotkey tap (bare modifier / combination / key + modifiers)
├── HotkeyRecorder.swift  Shortcut recorder for Settings (keyDown + flagsChanged)
├── NotchWindow.swift     Borderless always-on-top panel in the notch
├── NotchView.swift       SwiftUI pill UI (waveform, spinner, badges)
├── Visualizers.swift     5 LiveKit-style audio visualizers + settings preview
├── Models.swift          Whisper model catalog (Hugging Face ids)
├── HFModels.swift        Hugging Face search + repository metadata client
├── HFMetadataCache.swift Normalized metadata cache (stale-while-revalidate, offline-safe)
├── ModelDescriptor.swift Normalized model type + runtime registry + compatibility
├── ModelRegistry.swift   Installed-model records, lifecycle, favorites, removal
├── ModelDownloadQueue.swift Install queue over the existing downloaders (pause/resume/verify)
├── ModelStorage.swift    Storage location (+ migration), disk truth, usage report
├── ModelRecommender.swift Scoring, awards, language profile, battery awareness
├── ModelBenchmark.swift  Local benchmarking + usage analytics
├── ModelImport.swift     Import a model from disk (detect → validate → register)
├── ModelsView.swift      Models page (active / installed / recommended / discover / storage)
├── ModelDetailSheet.swift Full model detail: compatibility, capabilities, licence, files
├── ModelSheets.swift     Test playground, benchmark, compare, import, storage, downloads
├── ModelRows.swift       Model rows, cards, active panel, primary action
├── ModelsComponents.swift Status pills, metrics, banners, flow layout
├── LLMServer.swift       OpenAI-compatible chat client
├── LLMRunner.swift       Post-processing orchestration + chunking
├── LLMPrompts.swift      Per-mode system prompts
├── Dictionary.swift      Custom term / correction dictionary store
├── DictEditor.swift      Dictionary editor UI
├── History.swift         Transcript history store
├── FileTranscribeView.swift Upload page: pick/drop a file → decode → transcribe → editable text
├── MainView.swift        Main window: Home, Upload, Transcripts, Dictionary, Models
├── MenuBar.swift         Status-bar item + quick actions
├── AppVersion.swift      Build provenance read from Info.plist (commit, branch, repo)
├── UpdateChecker.swift   Polls GitHub for new commits on main + builds the changelog
├── Updater.swift         Downloads that commit, rebuilds, swaps the .app, relaunches
├── UpdateView.swift      Updates window + the "update available" banner
├── DesignTokens.swift    Theme + design system
└── Keychain.swift        Secure storage for the LLM API key
```

Two helper SwiftPM targets, `TranscribeTest` and `LiveRepro`, exercise transcription in isolation.

---

## Requirements

- macOS 14+ (built and tested on Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- Microphone permission (prompted on first record)
- Accessibility permission (to type into other apps)
- Input Monitoring permission (for the global hotkey; Accessibility is a reliable fallback)
- *Optional:* a local OpenAI-compatible LLM server for the [Local LLM](#local-llm-post-processing) feature

---

## Building & installing

`build.sh` resolves WhisperKit via SwiftPM, compiles a release executable, packages it as an ad-hoc- or self-signed `.app` in `build/`, and strips the *local* quarantine flag. Note: ad-hoc/self-signed builds are not trusted by Gatekeeper on other Macs — see Permissions & code signing for shipping a notarized release.

```bash
./build.sh
open build/NotchWhisper.app
```

Because the app is ad-hoc signed (no paid Developer ID), macOS may ask you to allow it the first time. Grant **Microphone** + **Accessibility** in System Settings → Privacy & Security when prompted.

> This is a script-compiled SwiftPM app (no `.xcodeproj`). Re-run `./build.sh` after any code change.

---

## Installing (build from source — no prebuilt binaries)

Prebuilt `.dmg` files are **not distributed** for now. The app is ad-hoc/self-signed, so a downloaded copy would trip Gatekeeper on other Macs (see Permissions & code signing). To run NotchWhisper, clone the repo and build it yourself:

```bash
git clone https://github.com/behkha/notchwhisper.git
cd notchwhisper
./build.sh
open build/NotchWhisper.app
```

`build.sh` accepts an `ARCH` variable (`arm64` / `x86_64` / `universal`; omit it to build for your Mac's architecture) and falls back to host arch. To package a `.dmg` for your own local use, run `./make_dmg.sh` (optionally with the arch suffix) after building.

### In-app updates

NotchWhisper follows the **`main` branch**, not tagged releases: `build.sh` stamps the commit it built from into `Info.plist` (`NWGitCommit`), and the app asks the GitHub API whether `main` has moved on. When it has, an **Update available** banner appears in the menu-bar panel and in **Settings → Updates**; opening it shows the commit range with each commit's message as the changelog.

**Update & Relaunch** then:

1. downloads that exact commit's source tarball into `~/Library/Caches/NotchWhisper/Updates` (your own checkout is never touched);
2. runs `build.sh` there — which vendors llama.cpp, compiles, and **re-signs with the same local `NotchWhisper Dev` identity**;
3. swaps the running `.app` for the result and relaunches it.

The rebuild is what keeps the app's TCC grants (Microphone, Input Monitoring, Accessibility) alive — a downloaded prebuilt binary would carry a different signature and reset every permission. In exchange, an update takes a few minutes and needs the Xcode command line tools. The build log is visible in the window while it runs, and *Skip this version* silences the banner until something newer lands.

Automatic checks run at launch and every 3 hours; turn them off in **Settings → Updates**, or check on demand from **NotchWhisper → Check for Updates…**.

**Releases.** Pushing a `v*` tag cuts a GitHub Release containing source archives only. The workflow at `.github/workflows/release.yml` is kept minimal on purpose; once Developer ID signing + notarization is wired up, it can be extended to build and attach notarized `.dmg`s again.

A **manual** run (**Actions → Release → Run workflow**) derives its release tag from the app's version (e.g. `v1.0`); you can also pass an explicit tag via the workflow's **tag** input. A tag-push run uses the pushed tag directly.

> Notes:
> - The first CI run compiles WhisperKit and its dependencies and can take 20–40+ minutes; subsequent architecture builds reuse SwiftPM's cache, so the full three-variant run is well within the 6-hour timeout.
> - Binaries are ad-hoc / self-signed, so users may need to right-click → **Open** on first launch. For a smoother install, sign with a Developer ID and notarize.
> - Models download on demand from Hugging Face, so each `.dmg` stays small.

---

## Permissions & code signing

macOS binds TCC grants (Accessibility, Input Monitoring, Microphone) to the app's **code signature**. Ad-hoc signing (`codesign -`) mints a new CDHash on every build, which silently orphans the grant: the System Settings toggle stays ON for the stale record, but the new binary is denied and prompts again on launch.

`NotchWhisper.app` avoids this by signing with a stable self-signed identity:

- `./setup_signing_identity.sh` — one-time setup; creates the **NotchWhisper Dev** code-signing certificate in the login keychain (valid 10 years).
- `./build.sh` signs with it automatically and falls back to ad-hoc with a loud warning if the identity is missing.

**Distributing the .dmg (GitHub Releases).** The self-signed "NotchWhisper Dev" identity and ad-hoc signing are local-only — they are *not* trusted by Gatekeeper on another Mac, so anyone who downloads the `.dmg` sees the "Apple could not verify … is free of malware" warning. To ship a warning-free release, sign the app with an Apple **Developer ID Application** certificate and **notarize** it: submit the built app (or `.dmg`) to Apple's notary service with `xcrun notarytool submit`, then staple the ticket with `xcrun stapler staple`. The release workflow can perform Developer ID signing + notarization automatically if you supply the certificate and notarization credentials as repository secrets.

If the permission prompt ever reappears after a rebuild:

1. `security find-identity -v -p codesigning` — confirm `NotchWhisper Dev` is listed and valid. If not, re-run `./setup_signing_identity.sh`.
2. `codesign -d -r- build/NotchWhisper.app` — the designated requirement must reference the NotchWhisper Dev cert, not plain ad-hoc.
3. If the requirement is right but access is still denied, clear the stale record once and re-grant: `tccutil reset Accessibility com.behkha.notchwhisper` (also `ListenEvent`, `PostEvent`, `Microphone`), then relaunch.

---

## Development & test hooks

NotchWhisper is a SwiftPM project (`Package.swift`), built with `./build.sh`. The repo also has two helper targets, `TranscribeTest` and `LiveRepro`, for isolated transcription testing.

Non-activating dev/test hooks (they never steal focus):

- `--wave-preview` — shows the notch pill with a simulated voice waveform so you can evaluate or screenshot the ribbon; it stays up until you quit the app.
- `--type-test "some text"` — types the text into the frontmost app via the normal AutoTyper path and exits (optional `--delay N` seconds to let the target app get focus first). An end-to-end test of dictation insertion with no UI and no microphone.
- `--file-selftest <audio-or-video-file>` — runs the Upload page's pipeline headless: decodes the file, loads the selected model, transcribes the whole clip with progress on stderr, and prints the transcript.
- `--mic-selftest` — checks the microphone choice (lid open and closed, unplugged, loopback-only) over made-up device lists, lists the live devices, and — with [BlackHole](https://github.com/ExistentialAudio/BlackHole) installed — records through the real recorder, meter and meeting recorder while `say` speaks into BlackHole, including a capture that moves off the built-in mic when the (simulated) lid closes. The routed capture is transcribed by the active model.
- `--simulate-lid-closed` — runs the app as though the MacBook were in clamshell mode, so the lid-closed fallback and messages can be checked with the lid open.
- `/tmp/nw_type_trigger` — a file whose contents are typed into the frontmost app ~2 s after launch; a diagnostic report is written to `/tmp/nw_typeresult.txt`.

---

## Contributing

Contributions are welcome:

1. Fork and clone the repo.
2. Create a branch (`git checkout -b my-change`).
3. Make your change, then build and run with `./build.sh`.
4. Open a pull request describing the what and why.

Please keep new behavior on-device by default and avoid introducing cloud dependencies without discussion.

---

## License

This project **does not currently ship a `LICENSE` file**. Until one is added, the default copyright (all rights reserved) applies and the code is not licensed for reuse. If you intend to use or distribute NotchWhisper, add a license or reach out to the author first.

---

## Troubleshooting

- **"Why isn't it typing?"** — Enable **Accessibility** for NotchWhisper in System Settings → Privacy & Security. Terminals (Terminal.app, iTerm, Warp) ignore Accessibility value writes, so NotchWhisper posts synthetic keystrokes there instead — that path needs **Input Monitoring** (or Accessibility) too.
- **"Apple could not verify NotchWhisper.app is free of malware" on first launch** — This is a *signing* warning, not malware. Locally built copies are signed ad-hoc (or with the local self-signed "NotchWhisper Dev" identity, which exists only on the build machine), so Gatekeeper on another Mac has no trusted signature to verify. To open it anyway: right-click the app → **Open** → click **Open** in the dialog (approves just this app), or run `xattr -dr com.apple.quarantine /Applications/NotchWhisper.app` in Terminal. For a clean, warning-free install for others, sign with an Apple **Developer ID Application** cert and **notarize** (see Permissions & code signing).
- **Hotkey doesn't fire / permission prompt reappears after a rebuild** — this is the ad-hoc signing issue above. Run `./setup_signing_identity.sh` once, rebuild, and re-grant permissions.
- **Local LLM says "can't connect"** — make sure your Ollama/LM Studio/Unsloth server is running and the **Endpoint** in Settings → Local LLM points at its `…/v1` address. Use **Test connection** to verify. Your text is sent only to that local endpoint.
- **Wrong word keeps appearing** — add it as a **Term** (to bias recognition) and/or a **Correction** (to fix the typed output) in the Dictionary tab.
- **Notch pill position with multiple displays** — it follows the pointer: it appears at the top centre of the display you're working on (inside the notch on the built-in one). With the lid closed it's the external display.
- **Nothing is typed with the lid closed** — the built-in mic is off in hardware while the lid is shut. Connect another microphone (see *With the lid closed*); Settings → Microphone shows which one NotchWhisper will use, and *Test* proves it hears you.
- **The wrong microphone is used** — pick it in Settings → Microphone or the menu bar. Automatic follows System Settings → Sound, except that with the lid closed it skips the built-in mic.
