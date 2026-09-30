import AppKit
import AVFoundation
import Carbon
import WhisperKit

// Entry point for a standard macOS app. The main thread is the MainActor, so
// we construct the @MainActor delegate here and let AppKit drive the lifecycle.
let app = NSApplication.shared

// `NotchWhisper --aura-selftest [out.png]` compiles the Aura shader at runtime,
// renders the speaking / thinking / listening states offscreen and checks the
// frames are neither blank nor saturated; the optional PNG is the speaking frame.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--aura-selftest") {
    let pngPath = CommandLine.arguments.count > flagIdx + 1 && !CommandLine.arguments[flagIdx + 1].hasPrefix("--")
        ? CommandLine.arguments[flagIdx + 1] : nil
    exit(AuraSelfTest.run(pngPath: pngPath))
}

// `NotchWhisper --vad-selftest` exercises the voice-activity gate (spec 04)
// over synthesised buffers — silence, a speech-shaped burst, a click, hiss —
// with no microphone. Exits 0 when every assertion holds.
if CommandLine.arguments.contains("--vad-selftest") {
    exit(VoiceActivitySelfTest.run())
}

// `NotchWhisper --live-text-selftest` checks the text rules live dictation
// depends on — spacing, skipping words already typed, Whisper's sound tags.
if CommandLine.arguments.contains("--live-text-selftest") {
    exit(LiveTextSelfTest.run())
}

// `NotchWhisper --mic-selftest` checks the input switcher and the lid-closed
// fallback: the choice rules, the live device list, and — with BlackHole
// installed — real captures routed to it while `say` speaks into it.
if CommandLine.arguments.contains("--mic-selftest") {
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        exitCode = await MicrophoneSelfTest.run()
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(exitCode)
}

// `NotchWhisper --meeting-selftest <audio-file>` runs the Meetings pipeline
// headless: the file becomes the mic channel of a two-channel WAV written by
// the meeting recorder's writer (header patched along the way, as during a
// recording), that WAV is read back the way a meeting is, then chunked and
// transcribed with timestamps by the active model.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--meeting-selftest"),
   CommandLine.arguments.count >= flagIdx + 2 {
    let path = CommandLine.arguments[flagIdx + 1]
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        defer { done = true }
        do {
            let source = try await AudioFileImport.loadSamples(from: URL(fileURLWithPath: path))
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("nw-meeting-selftest.wav")
            let writer = try WAVWriter(url: wav, channels: 2, sampleRate: 16_000)
            var offset = 0
            while offset < source.count {
                let end = min(source.count, offset + 8_000)
                let slice = Array(source[offset..<end])
                writer.append(left: slice, right: [Float](repeating: 0, count: slice.count))
                writer.flush()
                offset = end
            }
            writer.close()
            let back = try await AudioFileImport.loadSamples(from: wav)
            func rms(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))).squareRoot() }
            fputs("meeting-selftest: wrote \(source.count) frames, read back \(back.count); rms source=\(rms(source)) readback=\(rms(back)) (mono downmix of mic + silent system ≈ half)\n", stderr)
            guard abs(back.count - source.count) <= 32 else {
                fputs("meeting-selftest FAILED: frame count mismatch\n", stderr)
                exitCode = 1
                return
            }
            let transcriber = Transcriber(AppState.shared, Settings.shared)
            guard await transcriber.ensureLoaded() else {
                fputs("meeting-selftest FAILED: model not loaded\n", stderr)
                exitCode = 1
                return
            }
            let started = Date()
            let result = await MeetingTranscription.run(
                samples: back, transcriber: transcriber, sensitivity: .normal, trimSilence: true,
                biasTerms: [], onProgress: { p in fputs("meeting-selftest: \(Int(p * 100))%\n", stderr) }
            )
            fputs("meeting-selftest: \(result.segments.count) segments in \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n", stderr)
            for segment in result.segments {
                print("[\(segment.timestampLabel)–\(AudioFileImport.durationLabel(seconds: segment.end))] \(segment.text)")
            }
            if let failure = result.failure {
                fputs("meeting-selftest FAILED: \(failure)\n", stderr)
                exitCode = 1
            } else if result.segments.isEmpty {
                fputs("meeting-selftest FAILED: no segments\n", stderr)
                exitCode = 1
            }
        } catch {
            fputs("meeting-selftest FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(exitCode)
}

// `NotchWhisper --gguf-selftest <llamaModelId>` runs the GGUF download (resuming
// any partial files on disk) and prints the result — checks the resume path.
if let i = CommandLine.arguments.firstIndex(of: "--gguf-selftest"),
   CommandLine.arguments.count >= i + 2,
   let model = LlamaModelOption.find(id: CommandLine.arguments[i + 1]) {
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var code: Int32 = 0
    Task { @MainActor in
        let ok = await GGUFDownloader.download(model)
        fputs("gguf-selftest: download ok=\(ok) isDownloaded=\(GGUFDownloader.isDownloaded(model))\n", stderr)
        code = ok ? 0 : 1
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(code)
}

// `NotchWhisper --parakeet-download-selftest <parakeet:…>` runs the app's
// Parakeet download path (FluidAudio's transfer plus the disk-byte sampler the
// progress bar reads) and prints what the UI would show. It writes model files
// only — never the installation registry. Bad arguments exit rather than fall
// through to a full app launch.
if let i = CommandLine.arguments.firstIndex(of: "--parakeet-download-selftest") {
    guard CommandLine.arguments.count >= i + 2,
          let option = ParakeetModelOption.find(id: CommandLine.arguments[i + 1]) else {
        fputs("usage: --parakeet-download-selftest <\(ParakeetModelOption.all.map(\.id).joined(separator: "|"))>\n", stderr)
        exit(2)
    }
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var code: Int32 = 0
    Task { @MainActor in
        let state = AppState.shared
        let transcriber = Transcriber(state, Settings.shared)
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if state.isDownloading {
                    fputs("parakeet-download-selftest: \(state.downloadLabel) \(Int((state.displayProgress * 100).rounded()))% · \(state.downloadDetailText)\n", stderr)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let ok = await transcriber.download(modelId: option.id)
        ticker.cancel()
        let complete = ParakeetASR.isDownloaded(option)
        fputs("parakeet-download-selftest: ok=\(ok) isDownloaded=\(complete)\n", stderr)
        code = ok && complete ? 0 : 1
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(code)
}

// `NotchWhisper --models-selftest` prints how the model layer sees the Parakeet
// and Apple Speech engines on this Mac — install state, compatibility, live
// support — and how a Parakeet repository found on the Hub is routed. The
// registry runs read-only: it scans the real disk but writes nothing.
if CommandLine.arguments.contains("--models-selftest") {
    nonisolated(unsafe) var done = false
    Task { @MainActor in
        defer { done = true }
        ModelRegistry.readOnly = true
        let registry = ModelRegistry.shared
        await registry.scan()
        for d in ModelCatalogService.builtIn where d.engine == .fluidAudio || d.engine == .appleSpeech {
            let compat = ModelCompatibility.evaluate(d)
            print("\(d.id) · \(d.engine.detailName) · \(registry.lifecycle(of: d.id).label) · \(compat.verdict.label)"
                  + " · \(d.capabilities.languageCountLabel) · live=\(ModelEngine.supportsLive(d.id)) · trust=\(d.trust.label)")
            if compat.verdict.isBlocking { print("  why: \(compat.summary)") }
        }
        var query = HFHubQuery()
        query.text = "parakeet-tdt-0.6b-v3-coreml"
        let hub = (try? await HFHub.searchInstallable(query)) ?? []
        for model in hub where model.repoId.lowercased().hasPrefix("fluidinference/") {
            let d = ModelCatalogService.descriptor(forHubModel: model)
            print("hub \(model.repoId) → \(d.id) · \(d.engine.displayName) · installable=\(model.canInstall)")
        }
        if let meta = try? await HFModelSearch.fetchMetadata(repoId: "FluidInference/parakeet-tdt-0.6b-v3-coreml") {
            for v in meta.variants {
                print("variant \(v.id) · \(v.label) · \(v.sizeLabel) · supported=\(v.isSupported)")
            }
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// `NotchWhisper --llama-selftest <model.gguf> <mmproj.gguf> <audio.wav> ["context"]`
// runs the Qwen3-ASR (llama.cpp / mtmd) engine headless over a 16 kHz WAV and
// prints the transcript — an end-to-end check of the C integration with no UI.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--llama-selftest"),
   CommandLine.arguments.count >= flagIdx + 4 {
    let a = CommandLine.arguments
    let modelPath = a[flagIdx + 1], mmprojPath = a[flagIdx + 2], wavPath = a[flagIdx + 3]
    let context = a.count >= flagIdx + 5 ? a[flagIdx + 4] : ""

    func loadWav16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let ratio = 16000.0 / file.processingFormat.sampleRate
        var out: [Float] = []
        while true {
            let n = AVAudioFrameCount(min(Int(file.length - file.framePosition), 16384))
            guard n > 0 else { break }
            let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
            try file.read(into: inBuf, frameCount: n)
            var err: NSError?
            // Cap the output buffer to the exact resample ratio (+slack) so the
            // converter cannot over-pull the input block and duplicate samples.
            let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 16
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap)!
            var provided = false
            conv.convert(to: outBuf, error: &err) { _, s in
                if provided { s.pointee = .noDataNow; return nil }
                provided = true
                s.pointee = .haveData
                return inBuf
            }
            if let ch = outBuf.floatChannelData {
                out.append(contentsOf: Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength))))
            }
        }
        return out
    }

    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task.detached {
        do {
            let samples = try loadWav16k(wavPath)
            fputs("selftest: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000)) s)\n", stderr)
            let engine = LlamaASR()
            try await engine.load(
                modelId: "llama:selftest", modelPath: modelPath, mmprojPath: mmprojPath,
                threads: max(4, ProcessInfo.processInfo.activeProcessorCount - 2),
                progress: { p, label in fputs("selftest load: \(Int(p * 100))% \(label)\n", stderr) }
            )
            let started = Date()
            let text = try await engine.transcribe(samples, context: context)
            fputs("selftest: transcribe took \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n", stderr)
            print("TRANSCRIBED: \(text)")
            engine.shutdown()
        } catch {
            fputs("selftest FAILED: \(error)\n", stderr)
            exitCode = 1
        }
        sema.signal()
    }
    sema.wait()
    exit(exitCode)
}

// `NotchWhisper --live-bench <audio-file>` times one live-dictation pass of the
// re-decoding engines (Whisper, Parakeet) on windows of a few lengths. A pass
// re-decodes the whole unfinished phrase, so its cost is how far the caption
// trails the speaker. Apple Speech streams natively and has no pass to time.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--live-bench") {
    guard CommandLine.arguments.count >= flagIdx + 2 else {
        fputs("usage: --live-bench <audio-file>\n", stderr)
        exit(2)
    }
    let path = CommandLine.arguments[flagIdx + 1]
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        defer { done = true }
        do {
            let samples = try await AudioFileImport.loadSamples(from: URL(fileURLWithPath: path))
            let rate = Double(WhisperKit.sampleRate)
            let transcriber = Transcriber(AppState.shared, Settings.shared)
            guard await transcriber.ensureLoaded() else {
                fputs("live-bench FAILED: model not loaded\n", stderr)
                exitCode = 1
                return
            }
            let decode: ([Float]) async throws -> [LiveWord]
            switch transcriber.activeEngine {
            case .whisperKit:
                decode = { try await transcriber.whisperLiveWords($0) }
            case .fluidAudio:
                let language = transcriber.effectiveLanguage
                decode = { try await transcriber.parakeet.liveWords($0, languageCode: language) }
            case .appleSpeech, .llamaCPP:
                fputs("live-bench: \(transcriber.activeEngine.displayName) has no re-decode pass to time\n", stderr)
                exitCode = 1
                return
            }
            for seconds in [1.0, 2.0, 4.0, 8.0, 12.0] {
                let count = min(samples.count, Int(rate * seconds))
                let window = Array(samples.prefix(count))
                var times: [Double] = []
                var words: [LiveWord] = []
                for _ in 0..<4 {
                    let t0 = Date()
                    words = try await decode(window)
                    times.append(Date().timeIntervalSince(t0))
                }
                // Drop the first pass: it carries Core ML's lazy specialization.
                let warm = Array(times.dropFirst())
                let mean = warm.reduce(0, +) / Double(warm.count)
                print(String(format: "window %4.1fs  first %5.0f ms  warm %5.0f ms  words %3d  spans %d",
                             seconds, times[0] * 1000, mean * 1000, words.count,
                             Set(words.map { "\($0.start)-\($0.end)" }).count))
            }
        } catch {
            fputs("live-bench FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(exitCode)
}

// `NotchWhisper --live-selftest <audio-file> [options]` replays a recording
// through the REAL live-dictation session in real time — recognizer, formatting
// and typist — with no microphone. By default the keystrokes go to a virtual
// page instead of the focused app, and the test checks that page ends up
// exactly as the session's final transcript. It also reports how long each
// word took to appear and how much text was typed and taken back.
//
//   --settled            type final text only ("Correct as you speak" off)
//   --pause-every <s>    insert --pause-length (default 1.5 s) of silence after
//                        every <s> seconds of audio, to exercise phrase endings
//   --interrupt <s>      simulate the user clicking into the page at <s>
//   --hold-at-stop <s>   typing is held back for <s> after stop, as while the
//                        default ⌥ stop key is still down
//   --type <App> [--delay <s>]  send real keystrokes to <App> (e.g. TextEdit)
//                        instead. Refuses to start unless <App> is in front,
//                        and stops typing the moment it isn't — never run it
//                        while someone is using the Mac.
//   --verbose            print every page edit
//
// Pass `-modelId <id>` after the options to pick the engine without touching
// the saved setting.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--live-selftest") {
    let args = CommandLine.arguments
    guard args.count >= flagIdx + 2, !args[flagIdx + 1].hasPrefix("-") else {
        fputs("usage: --live-selftest <audio-file> [--settled] [--pause-every s] [--pause-length s] [--interrupt s] [--type [--delay s]] [--verbose]\n", stderr)
        exit(2)
    }
    let path = args[flagIdx + 1]
    func value(_ flag: String) -> Double? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }
    let settled = args.contains("--settled")
    let realTyping = args.contains("--type")
    let typeTarget = args.firstIndex(of: "--type").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    if realTyping, typeTarget == nil || typeTarget!.hasPrefix("-") {
        fputs("live-selftest: --type needs the name of the app to type into, e.g. --type TextEdit\n", stderr)
        exit(2)
    }
    let verbose = args.contains("--verbose")
    let pauseEvery = value("--pause-every")
    let pauseLength = value("--pause-length") ?? 1.5
    let interruptAt = value("--interrupt")
    let holdAtStop = value("--hold-at-stop")
    let delay = value("--delay") ?? 0
    for flag in ["--pause-every", "--pause-length", "--interrupt", "--delay", "--hold-at-stop"]
    where args.contains(flag) && value(flag) == nil {
        fputs("live-selftest: \(flag) needs a number of seconds\n", stderr)
        exit(2)
    }
    // Headless: no Dock icon, never takes focus from whoever is using the Mac.
    // The activity keeps App Nap off, as a real dictation does — a napping
    // process gets its timers coalesced and its Neural Engine work queued
    // behind everyone else's, which would skew every timing this measures.
    if !realTyping { NSApp.setActivationPolicy(.prohibited) }
    let replayActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "live-selftest replay")
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        defer { done = true }
        do {
            var samples = try await AudioFileImport.loadSamples(from: URL(fileURLWithPath: path))
            let rate = Double(WhisperKit.sampleRate)
            if let every = pauseEvery, every > 0 {
                var out: [Float] = []
                var i = 0
                while i < samples.count {
                    let end = min(samples.count, i + Int(every * rate))
                    out += samples[i..<end]
                    if end < samples.count { out += [Float](repeating: 0, count: Int(pauseLength * rate)) }
                    i = end
                }
                samples = out
            }
            fputs("live-selftest: \(AudioFileImport.durationLabel(samples: samples.count)) of audio\n", stderr)

            let state = AppState.shared
            let settings = Settings.shared
            settings.liveRewrites = !settled
            let recorder = AudioRecorder(state, settings)
            let transcriber = Transcriber(state, settings)
            let live = LiveTranscriber(state, settings, recorder, transcriber)

            // The virtual page: exactly what the keystrokes would leave in a
            // text field that nobody else touches.
            var page: [Character] = []
            var edits = 0
            var deleted = 0
            var inserted = 0
            var badDelete = false
            var started = Date()
            var history: [(t: Double, page: String)] = []
            if realTyping {
                live.autoTypeOverride = true
            } else {
                live.caretProbeOverride = { page.last }
                live.typingOverride = { deleting, inserting in
                    if deleting > page.count { badDelete = true }
                    page.removeLast(min(deleting, page.count))
                    page.append(contentsOf: inserting)
                    edits += 1
                    deleted += deleting
                    inserted += inserting.count
                    let t = Date().timeIntervalSince(started)
                    history.append((t, String(page)))
                    if verbose {
                        fputs(String(format: "[%6.2f] ", t) + (deleting > 0 ? "−\(deleting) " : "")
                              + "+\"\(inserting)\"  →  …\(String(page).suffix(70))\n", stderr)
                    }
                    return "queued"
                }
            }

            RedecodeLiveRecognizer.debugLog = verbose
            guard await transcriber.ensureLoaded() else {
                fputs("live-selftest FAILED: model not loaded\n", stderr)
                exitCode = 1
                return
            }
            if realTyping, delay > 0 {
                fputs("live-selftest: typing into the frontmost app in \(delay) s\n", stderr)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var typingBlocked = false
            if realTyping {
                // Pin the keystrokes to the NAMED app, and only while it is in
                // front: typing stops the moment focus moves, instead of
                // landing in whatever the user is working in.
                guard let front = NSWorkspace.shared.frontmostApplication,
                      front.localizedName == typeTarget else {
                    fputs("live-selftest FAILED: \(typeTarget ?? "?") is not the app in front — not typing anywhere\n", stderr)
                    exitCode = 2
                    return
                }
                let pid = front.processIdentifier
                fputs("live-selftest: typing into \(front.localizedName ?? "?") (pid \(pid),"
                      + " Accessibility trusted: \(AutoTyper.isTrusted))\n", stderr)
                live.typingGuard = {
                    let ok = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                    if !ok { typingBlocked = true }
                    return ok
                }
            }

            recorder.startSynthetic()
            let t0 = Date()
            started = t0
            live.start()
            // Feed in 100 ms chunks pinned to wall clock, the arrival pattern a
            // microphone produces.
            let chunk = Int(rate / 10)
            var fed = 0
            var interrupted = false
            while fed < samples.count {
                let end = min(fed + chunk, samples.count)
                recorder.feed(Array(samples[fed..<end]))
                fed = end
                let audioElapsed = Double(fed) / rate
                if let at = interruptAt, !interrupted, audioElapsed >= at {
                    interrupted = true
                    live.simulateUserTookOver()
                    fputs(String(format: "live-selftest: simulated a click into the page at %.1f s\n", audioElapsed), stderr)
                }
                let wallElapsed = Date().timeIntervalSince(t0)
                if audioElapsed > wallElapsed {
                    try? await Task.sleep(nanoseconds: UInt64((audioElapsed - wallElapsed) * 1_000_000_000))
                }
            }
            let fedAt = Date().timeIntervalSince(t0)
            if let hold = holdAtStop { live.holdTypingForTest(until: Date().addingTimeInterval(hold)) }
            let result = await live.stop()
            let stoppedAt = Date().timeIntervalSince(t0)

            let audioSeconds = Double(samples.count) / rate
            fputs("live-selftest: audio \(String(format: "%.1f", audioSeconds))s"
                  + " · fed by \(String(format: "%.1f", fedAt))s"
                  + " · final pass done at \(String(format: "%.1f", stoppedAt))s"
                  + " (tail cost \(String(format: "%.2f", stoppedAt - fedAt))s)\n", stderr)
            print("LIVE FINAL: \(result.final)")
            if realTyping {
                // Let the typing queue drain before anyone reads the target.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                print(typingBlocked
                      ? "(focus left the target app — typing stopped there; nothing went elsewhere)"
                      : "(typed into the frontmost app — compare it with LIVE FINAL)")
                return
            }
            let pageText = String(page)
            print("LIVE PAGE:  \(pageText)")
            print("EDITS: \(edits) · typed \(inserted) chars · took back \(deleted) chars"
                  + " (\(inserted > 0 ? Int((Double(deleted) / Double(inserted) * 100).rounded()) : 0)% rewritten)")

            // How long each word of the final text took to appear, in place,
            // after it was spoken: the first moment the page carried the
            // word at its position. Audio is fed in real time, so wall
            // time after start is audio time.
            let finalKeys = pageText.split(separator: " ").map { LiveText.key(String($0)) }
            var firstSeen = [Double?](repeating: nil, count: finalKeys.count)
            var settledAt = [Double?](repeating: nil, count: finalKeys.count)
            for (t, text) in history {
                let keys = text.split(separator: " ").map { LiveText.key(String($0)) }
                for i in 0..<min(keys.count, finalKeys.count) where keys[i] == finalKeys[i] {
                    if firstSeen[i] == nil { firstSeen[i] = t }
                }
                for i in 0..<finalKeys.count {
                    let ok = i < keys.count && keys[i] == finalKeys[i]
                    if ok { if settledAt[i] == nil { settledAt[i] = t } } else { settledAt[i] = nil }
                }
            }
            let seen = firstSeen.compactMap { $0 }
            if !seen.isEmpty, !interrupted {
                // Word end times come from the recognizer's final words.
                print(String(format: "WORDS: %d on the page · every word right by %.1f s after start of audio",
                             finalKeys.count, settledAt.compactMap { $0 }.max() ?? 0))
            }

            var failures: [String] = []
            if badDelete { failures.append("a Backspace ran past the start of the page") }
            if !interrupted, pageText != result.final {
                failures.append("the page is not the final transcript")
            }
            if result.final.contains("  ") { failures.append("double space in the transcript") }
            if failures.isEmpty {
                fputs("live-selftest: PASS\n", stderr)
            } else {
                for f in failures { fputs("live-selftest FAILED: \(f)\n", stderr) }
                exitCode = 1
            }
        } catch {
            fputs("live-selftest FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    // Pump AppKit events, as the app's run loop does: global event monitors
    // (the typist's watch for the user taking over) are delivered this way.
    while !done {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    ProcessInfo.processInfo.endActivity(replayActivity)
    exit(exitCode)
}

// `NotchWhisper --file-selftest <audio-or-video-file>` runs the Upload page's
// pipeline headless: decode the file to 16 kHz mono, load the selected model,
// transcribe the whole clip with progress, and print the transcript.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--file-selftest"),
   CommandLine.arguments.count >= flagIdx + 2 {
    let path = CommandLine.arguments[flagIdx + 1]
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        defer { done = true }
        do {
            let samples = try await AudioFileImport.loadSamples(from: URL(fileURLWithPath: path))
            fputs("file-selftest: \(samples.count) samples (\(AudioFileImport.durationLabel(samples: samples.count)))\n", stderr)
            let transcriber = Transcriber(AppState.shared, Settings.shared)
            guard await transcriber.ensureLoaded() else {
                fputs("file-selftest FAILED: model not loaded\n", stderr)
                exitCode = 1
                return
            }
            let started = Date()
            let text = try await transcriber.transcribeFile(
                samples,
                biasTerms: DictionaryStore.shared.biasingTerms(),
                onProgress: { p in fputs("file-selftest: \(Int(p * 100))%\n", stderr) }
            )
            fputs("file-selftest: took \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n", stderr)
            print("TRANSCRIBED: \(text)")
        } catch {
            fputs("file-selftest FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(exitCode)
}

// `NotchWhisper --type-test "some text"` types the text into the frontmost app
// via the normal AutoTyper path and exits — an end-to-end test of dictation
// insertion with no UI and no microphone needed.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--type-test"),
   CommandLine.arguments.count > flagIdx + 1 {
    let text = CommandLine.arguments[flagIdx + 1]
    // Optional --delay N (seconds) to let the target app get focus first.
    var delay: Double = 0
    if let dIdx = CommandLine.arguments.firstIndex(of: "--delay"),
       CommandLine.arguments.count > dIdx + 1, let d = Double(CommandLine.arguments[dIdx + 1]) {
        delay = d
    }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    MainActor.assumeIsolated {
        fputs("type-test: trusted=\(AutoTyper.isTrusted) result=\(AutoTyper.typeBlocking(text))\n", stderr)
    }
    exit(0)
}

// `NotchWhisper --paste-test "text" [--delay N]` inserts text into the frontmost
// app through the CLIPBOARD path (the one used for terminal programs), then
// restores the clipboard — the paste-insertion counterpart of --type-test.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--paste-test"),
   CommandLine.arguments.count > flagIdx + 1 {
    let text = CommandLine.arguments[flagIdx + 1]
    var delay: Double = 0
    if let dIdx = CommandLine.arguments.firstIndex(of: "--delay"),
       CommandLine.arguments.count > dIdx + 1, let d = Double(CommandLine.arguments[dIdx + 1]) {
        delay = d
    }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    MainActor.assumeIsolated {
        let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "—"
        fputs("paste-test: target=\(target)\n", stderr)
        fputs("paste-test: \(AutoTyper.paste(text))\n", stderr)
    }
    // RUN the main loop rather than sleeping on it: the clipboard restore is
    // dispatched back to main, and a sleeping main thread would never run it.
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    exit(0)
}

// `NotchWhisper --terminal-scan` lists every foreground command running in the
// frontmost terminal — one per tab, with the pid and tty it was resolved from.
// The diagnostic for "why did it think I was in X?".
if CommandLine.arguments.contains("--terminal-scan") {
    MainActor.assumeIsolated {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            print("no frontmost app"); exit(1)
        }
        print("terminal: \(bundleID) pid=\(app.processIdentifier) known=\(AppContext.terminalBundleIDs.contains(bundleID))")
        let context = AppContext.current()
        print("title:    \(context.windowTitle ?? "—")")
        for tool in TerminalProcess.foregroundTools(ofTerminal: app.processIdentifier) {
            print("  tty=\(tool.tty) pid=\(tool.pid) \(tool.name)\(tool.isShell ? " (shell)" : "")")
        }
        print("resolved: \(context.cliTool ?? "—")")
    }
    exit(0)
}

// `NotchWhisper --app-context [<bundle-id>] [--delay N]` prints the destination
// NotchWhisper would resolve — the frontmost app (or the bundle id given), the
// focused field's role, the matching app profile and the settings that profile
// produces. Lets app-profile behaviour be checked without a microphone; passing
// a bundle id makes it deterministic (no need to give another app focus).
if let acIdx = CommandLine.arguments.firstIndex(of: "--app-context") {
    var delay: Double = 2
    if let dIdx = CommandLine.arguments.firstIndex(of: "--delay"),
       CommandLine.arguments.count > dIdx + 1, let d = Double(CommandLine.arguments[dIdx + 1]) {
        delay = d
    }
    // An argument right after the flag that isn't another flag is a bundle id.
    var forcedBundleID: String?
    if CommandLine.arguments.count > acIdx + 1, !CommandLine.arguments[acIdx + 1].hasPrefix("--") {
        forcedBundleID = CommandLine.arguments[acIdx + 1]
        delay = 0
    }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    MainActor.assumeIsolated {
        var context = AppContext.current()
        if let forcedBundleID {
            context = AppContext(bundleID: forcedBundleID,
                                 appName: AppCatalog.name(for: forcedBundleID),
                                 fieldRole: AppContext.terminalBundleIDs.contains(forcedBundleID) ? .terminal : .unknown)
        }
        let effective = AppProfileStore.shared.effective(for: context)
        print("context:  \(context.debugSummary)")
        print("profile:  \(effective.profileName ?? "— (global settings)")")
        print("mode:     \(CustomModeStore.shared.label(for: effective.processingMode))")
        print("typing:   autoType=\(effective.autoType) newline=\(effective.insertNewline) insert=\(effective.insertionMode.rawValue)")
        print("model:    \(effective.modelId)\(effective.modelFromProfile ? " (from profile)" : "")")
        if effective.pinnedConnectionMissing { print("warning:  pinned connection missing") }
        print("llm:      enabled=\(effective.llmEnabled)")
        // Opt-in, because resolving the connection wakes `LLMConnectionStore`,
        // which reads the Keychain — and an unsigned `swift build` binary
        // BLOCKS there on a system authorization prompt. Pass --with-llm when
        // running the signed build/NotchWhisper.app binary.
        if CommandLine.arguments.contains("--with-llm") {
            fflush(stdout)
            print("llm run:  active=\(effective.llmActive) connection=\(effective.connection?.name ?? "—")")
        }
    }
    exit(0)
}

// `NotchWhisper --hotkey-dump` prints the stored hotkey bindings and the
// trigger table the monitor builds from them — key codes, required modifiers
// and the specificity that decides which one wins a shared event. No tap is
// installed and no permission is needed, so this runs headless anywhere.
if CommandLine.arguments.contains("--hotkey-dump") {
    MainActor.assumeIsolated {
        let store = HotkeyBindingStore.shared
        print("bindings: \(store.bindings.count) (\(store.enabledCount) enabled)")
        for binding in store.bindings {
            let key = binding.keyCode == 0 ? "—" : binding.display
            print("  \(binding.enabled ? "on " : "off") \(key.padding(toLength: max(10, key.count), withPad: " ", startingAt: 0))"
                  + "  \(binding.effectiveActivation.rawValue)\(binding.activation == nil ? " (inherited)" : "")  overrides=\(binding.overrideCount)  \(binding.name)")
            if let mode = binding.processingMode {
                print("        mode=\(CustomModeStore.shared.label(for: mode))")
            }
            if let warning = store.shadowWarning(for: binding) { print("        warning: \(warning)") }
            if let dupe = store.duplicate(of: binding) { print("        duplicate of: \(dupe.name)") }
            if let system = store.systemWarning(for: binding) { print("        system shortcut: \(system)") }
        }
        // Same construction the delegate installs, minus the tap itself.
        let monitor = HotkeyMonitor(onDown: { _ in }, onUp: { _ in })
        monitor.installTableOnly(store.installable)
        print("trigger table (most specific first):")
        print(monitor.dump(), terminator: "")
        print("permission: inputMonitoring/accessibility granted=\(HotkeyMonitor.hasPermission)")
        print("liveDictation setting=\(Settings.shared.liveDictation) model=\(Settings.shared.modelId)")
    }
    exit(0)
}

// `NotchWhisper --hotkey-selftest` drives the trigger table with SYNTHETIC
// events — the same resolution path the CGEvent tap callback uses — and asserts
// the invariants that are impossible to eyeball: one active session at a time,
// specificity ordering, the bare-modifier debounce, and that a broken modifier
// combination releases. Needs no permission and no microphone.
if CommandLine.arguments.contains("--hotkey-selftest") {
    nonisolated(unsafe) var failures = 0

    /// Runs one scenario and reports the (down, up) ids it produced.
    @MainActor
    func scenario(_ name: String, bindings: [HotkeyBinding],
                  expect: [String],
                  _ steps: (HotkeyMonitor) -> Void) {
        nonisolated(unsafe) var log: [String] = []
        let names = Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, $0.name) })
        let monitor = HotkeyMonitor(
            onDown: { id in log.append("down:\(names[id] ?? "?")") },
            onUp:   { id in log.append("up:\(names[id] ?? "?")") }
        )
        monitor.installTableOnly(bindings)
        steps(monitor)
        // Let the bare-modifier debounce fire (it is scheduled on the main queue).
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let ok = log == expect
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok {
            print("       expected: \(expect.joined(separator: ", "))")
            print("       actual:   \(log.joined(separator: ", "))")
        }
    }

    MainActor.assumeIsolated {
        let bareOption = HotkeyBinding(name: "bare⌥", keyCode: 58)
        // "hold ⌥, tap ⌃" — what HotkeyRecorder commits for that gesture.
        let controlWithOption = HotkeyBinding(name: "⌥+⌃", keyCode: 59,
                                              carbonModifiers: UInt32(optionKey))
        // "hold ⌃, tap ⌥".
        let optionWithControl = HotkeyBinding(name: "⌃+⌥", keyCode: 58,
                                              carbonModifiers: UInt32(controlKey))
        let plainD = HotkeyBinding(name: "D", keyCode: 2)
        let comboD = HotkeyBinding(name: "⌃⌥D", keyCode: 2,
                                   carbonModifiers: UInt32(controlKey) | UInt32(optionKey))

        // 1. Specificity: ⌃ already held, ⌥ completes the combination. The
        //    specific trigger wins the event the bare one also matches.
        scenario("specificity: ⌃⌥ beats bare ⌥",
                 bindings: [bareOption, optionWithControl],
                 expect: ["down:⌃+⌥", "up:⌃+⌥"]) { m in
            m.simulate(keyCode: 59, flags: [.maskControl])                     // ⌃ down
            m.simulate(keyCode: 58, flags: [.maskControl, .maskAlternate])     // ⌥ down
            m.simulate(keyCode: 58, flags: [.maskControl])                     // ⌥ up
            m.simulate(keyCode: 59, flags: [])                                 // ⌃ up
        }

        // 2. The debounce: ⌥ goes down first and would fire the bare trigger,
        //    but ⌃ lands inside the window and the specific one takes it.
        scenario("debounce: bare ⌥ yields to ⌥+⌃",
                 bindings: [bareOption, controlWithOption],
                 expect: ["down:⌥+⌃", "up:⌥+⌃"]) { m in
            m.simulate(keyCode: 58, flags: [.maskAlternate])                   // ⌥ down
            m.simulate(keyCode: 59, flags: [.maskAlternate, .maskControl])     // ⌃ down
            m.simulate(keyCode: 59, flags: [.maskAlternate])                   // ⌃ up
            m.simulate(keyCode: 58, flags: [])                                 // ⌥ up
        }

        // 3. Nothing more specific arrives: the bare trigger commits on its own.
        scenario("debounce: bare ⌥ still fires alone",
                 bindings: [bareOption, controlWithOption],
                 expect: ["down:bare⌥", "up:bare⌥"]) { m in
            m.simulate(keyCode: 58, flags: [.maskAlternate])
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            m.simulate(keyCode: 58, flags: [])
        }

        // 4. One microphone, one session: a second trigger pressed while one is
        //    active is ignored, and its release fires nothing.
        scenario("one session at a time",
                 bindings: [bareOption, plainD],
                 expect: ["down:bare⌥", "up:bare⌥"]) { m in
            m.simulate(keyCode: 58, flags: [.maskAlternate])
            m.simulate(keyCode: 2, flags: [.maskAlternate], keyEvent: true)    // D down — ignored
            m.simulate(keyCode: 2, flags: [.maskAlternate], keyEvent: false)   // D up   — silent
            m.simulate(keyCode: 58, flags: [])
        }

        // 5. Key repeat: keyDown fires over and over while held; the pressed
        //    != isDown guard swallows every repeat.
        scenario("key repeat is swallowed",
                 bindings: [plainD],
                 expect: ["down:D", "up:D"]) { m in
            m.simulate(keyCode: 2, flags: [], keyEvent: true)
            m.simulate(keyCode: 2, flags: [], keyEvent: true)
            m.simulate(keyCode: 2, flags: [], keyEvent: true)
            m.simulate(keyCode: 2, flags: [], keyEvent: false)
        }

        // 6. A broken combination releases: letting ⌃ go while ⌃⌥D is held
        //    ends the session rather than stranding it down.
        scenario("broken combination releases",
                 bindings: [comboD],
                 expect: ["down:⌃⌥D", "up:⌃⌥D"]) { m in
            m.simulate(keyCode: 2, flags: [.maskControl, .maskAlternate], keyEvent: true)
            m.simulate(keyCode: 59, flags: [.maskAlternate])                   // ⌃ released
            m.simulate(keyCode: 2, flags: [.maskAlternate], keyEvent: false)   // D up — already released
        }

        // 7. Specificity again, on a regular key shared by two bindings.
        scenario("specificity: ⌃⌥D beats bare D",
                 bindings: [plainD, comboD],
                 expect: ["down:⌃⌥D", "up:⌃⌥D"]) { m in
            m.simulate(keyCode: 2, flags: [.maskControl, .maskAlternate], keyEvent: true)
            m.simulate(keyCode: 2, flags: [.maskControl, .maskAlternate], keyEvent: false)
        }

        // 8. uninstall() while a trigger is held fires the synthetic up, or the
        //    next release is swallowed and recording never stops.
        scenario("uninstall releases a held trigger",
                 bindings: [bareOption],
                 expect: ["down:bare⌥", "up:bare⌥"]) { m in
            m.simulate(keyCode: 58, flags: [.maskAlternate])
            m.uninstall()
        }
    }

    print(failures == 0 ? "hotkey-selftest: all scenarios passed"
                        : "hotkey-selftest: \(failures) scenario(s) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// `NotchWhisper --hub-search <query> [--all] [--lang <code>]` runs one real Hugging Face
// search and prints what the browse sheet would render — the parsed fields and
// the installability verdict for each result. Checks the Hub client without a
// window, and diagnoses "why is that model missing?" reports.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--hub-search") {
    let query = CommandLine.arguments.count > flagIdx + 1
        && !CommandLine.arguments[flagIdx + 1].hasPrefix("--")
        ? CommandLine.arguments[flagIdx + 1] : ""
    let showAll = CommandLine.arguments.contains("--all")
    let language = CommandLine.arguments.firstIndex(of: "--lang").flatMap { i -> String? in
        CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
    }
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 0

    Task {
        defer { sem.signal() }
        var hubQuery = HFHubQuery()
        hubQuery.text = query
        hubQuery.language = language
        do {
            // Mirrors the sheet: "runs here" fans out over the installable
            // formats and the untagged variants; "everything" is one plain
            // query over the whole Hub.
            var more = false
            let fetched: [HFHubModel]
            if showAll {
                let page = try await HFHub.search(hubQuery)
                fetched = page.models
                more = page.nextCursor != nil
            } else {
                fetched = try await HFHub.searchInstallable(hubQuery)
            }
            let shown = showAll ? fetched : fetched.filter(\.canInstall)
            print("query: \(query.isEmpty ? "(none)" : query) · sort \(hubQuery.sort.rawValue)"
                  + " · scope \(showAll ? "everything" : "runs here")"
                  + (language.map { " · language \(ModelCapabilities.languageName($0))" } ?? ""))
            print("\(fetched.count) results · \(fetched.filter(\.canInstall).count) installable"
                  + (more ? " · more pages available" : ""))
            for model in shown {
                let mark = model.canInstall ? "OK " : "-- "
                print("\(mark)\(model.repoId)")
                var facts: [String] = [model.installability.format.displayName]
                if let params = model.parameterLabel { facts.append("\(params) params") }
                if let size = model.sizeLabel { facts.append(size) }
                facts.append("\(model.languages.count) langs")
                facts.append(model.license ?? "no licence")
                facts.append("\(HFHub.compact(model.downloads30d))/30d")
                facts.append("\(HFHub.compact(model.likes)) likes")
                if model.trendingScore > 0 { facts.append("trending \(model.trendingScore)") }
                if model.isGated { facts.append("gated") }
                print("     " + facts.joined(separator: " · "))
                if let wer = model.headlineWER { print("     accuracy: \(wer.valueLabel) \(wer.metricLabel) (\(wer.datasetLabel))") }
                if let speed = model.headlineSpeed { print("     speed: \(speed.valueLabel)") }
                if let reason = model.installability.reason { print("     reason: \(reason)") }
            }
        } catch {
            print("hub-search FAILED: \(error.localizedDescription)")
            code = 1
        }
    }
    sem.wait()
    exit(code)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.run()
