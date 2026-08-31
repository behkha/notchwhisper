import AppKit
import AVFoundation

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
        _ = AutoTyper.typeBlocking(text)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.run()
