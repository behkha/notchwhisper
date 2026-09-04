import AppKit
import AVFoundation
import Carbon
import WhisperKit

// Entry point for a standard macOS app. The main thread is the MainActor, so
// we construct the @MainActor delegate here and let AppKit drive the lifecycle.
let app = NSApplication.shared

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

// `NotchWhisper --live-bench <audio-file>` times the live decode on windows of
// a few different lengths. Live dictation can only ever be as smooth as one
// decode pass, so this is the number to look at before tuning the loop around
// it: a pass that costs more than it captures can never catch up.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--live-bench"),
   CommandLine.arguments.count >= flagIdx + 2 {
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
            let bias = DictionaryStore.shared.biasingTerms()
            for seconds in [1.0, 2.0, 4.0, 8.0] {
                let count = min(samples.count, Int(rate * seconds))
                let window = Array(samples.prefix(count))
                var times: [Double] = []
                for _ in 0..<4 {
                    let t0 = Date()
                    _ = try await transcriber.liveTranscribe(window, biasTerms: bias)
                    times.append(Date().timeIntervalSince(t0))
                }
                // Drop the first pass: it carries CoreML's lazy specialization.
                let warm = Array(times.dropFirst())
                let mean = warm.reduce(0, +) / Double(warm.count)
                print(String(format: "window %4.1fs  first %5.0f ms  warm %5.0f ms  realtime factor %.2f",
                             seconds, times[0] * 1000, mean * 1000, mean / seconds))
            }
        } catch {
            fputs("live-bench FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(exitCode)
}

// `NotchWhisper --live-selftest <audio-file>` replays a file through the REAL
// live-dictation loop in real time — no microphone, no permission, no typing.
// It exists to make the loop's latency measurable: every pass prints its decode
// cost and every commit prints how far behind the live edge the typed text is.
if let flagIdx = CommandLine.arguments.firstIndex(of: "--live-selftest"),
   CommandLine.arguments.count >= flagIdx + 2 {
    let path = CommandLine.arguments[flagIdx + 1]
    nonisolated(unsafe) var done = false
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task { @MainActor in
        defer { done = true }
        do {
            let samples = try await AudioFileImport.loadSamples(from: URL(fileURLWithPath: path))
            let rate = Double(WhisperKit.sampleRate)
            fputs("live-selftest: \(AudioFileImport.durationLabel(samples: samples.count)) of audio\n", stderr)

            let state = AppState.shared
            let settings = Settings.shared
            let recorder = AudioRecorder(state, settings)
            let transcriber = Transcriber(state, settings)
            let live = LiveTranscriber(state, settings, recorder, transcriber)
            // Measure the loop, never touch the user's focused window.
            live.autoTypeOverride = false

            guard await transcriber.ensureLoaded() else {
                fputs("live-selftest FAILED: model not loaded\n", stderr)
                exitCode = 1
                return
            }

            recorder.startSynthetic()
            let started = Date()
            live.start()

            // Feed in 100 ms chunks pinned to wall clock, so the loop sees the
            // same arrival pattern a microphone would produce.
            let chunk = Int(rate / 10)
            var fed = 0
            while fed < samples.count {
                let end = min(fed + chunk, samples.count)
                recorder.feed(Array(samples[fed..<end]))
                fed = end
                let audioElapsed = Double(fed) / rate
                let wallElapsed = Date().timeIntervalSince(started)
                if audioElapsed > wallElapsed {
                    try? await Task.sleep(nanoseconds: UInt64((audioElapsed - wallElapsed) * 1_000_000_000))
                }
            }
            let fedAt = Date().timeIntervalSince(started)
            let result = await live.stop()
            let stoppedAt = Date().timeIntervalSince(started)

            let audioSeconds = Double(samples.count) / rate
            fputs("live-selftest: audio \(String(format: "%.1f", audioSeconds))s"
                  + " · fed by \(String(format: "%.1f", fedAt))s"
                  + " · final flush done at \(String(format: "%.1f", stoppedAt))s"
                  + " (tail cost \(String(format: "%.1f", stoppedAt - fedAt))s)\n", stderr)
            print("LIVE TYPED: \(result.final)")
            print("LIVE RAW:   \(result.raw)")
        } catch {
            fputs("live-selftest FAILED: \(error)\n", stderr)
            exitCode = 1
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
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
