import Foundation
import WhisperKit

/// Wraps WhisperKit (CoreML Whisper) for local, offline transcription.
/// Models are downloaded on demand from Hugging Face (argmaxinc/whisperkit-coreml).
@MainActor final class Transcriber {
    private let state: AppState
    private let settings: Settings
    private let fileManager = FileManager.default

    private var whisper: WhisperKit?
    private var loadedModelId: String?

    /// Second engine: GGUF Qwen3-ASR via llama.cpp / mtmd. Loaded only while the
    /// active model id is `llama:*`; hold-to-talk (batch) transcription only.
    let llama = LlamaASR()

    /// The single in-flight load, so concurrent callers (the `.modelChanged`
    /// notification, `requestDownload`, a dictation start, the launch task)
    /// share ONE `WhisperKit` construction instead of racing several. Racing
    /// loads is the "downloaded model doesn't activate until relaunch" bug:
    /// two concurrent CoreML compiles on the same folder collide, one throws,
    /// and the failed one is the one whose result the UI observes.
    private var loadTask: Task<Bool, Never>?
    private var loadingModelId: String?

    var modelDir: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/Models")
    }

    init(_ state: AppState, _ settings: Settings) {
        self.state = state
        self.settings = settings
    }

    /// Custom (Hugging Face search) model ids use "<repoId>:<folder>".
    static func parseCustom(_ modelId: String) -> (repo: String, folder: String)? {
        guard modelId.contains(":"), !modelId.hasPrefix("whisper-"), !modelId.hasPrefix("distil-") else { return nil }
        let parts = modelId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Load (downloading if needed) the model selected in settings.
    func ensureLoaded() async -> Bool {
        await ensureLoaded(modelId: settings.modelId)
    }

    /// Load a specific model, coalescing with any in-flight load of the same
    /// model and cancelling an in-flight load of a *different* one.
    @discardableResult
    func ensureLoaded(modelId: String) async -> Bool {
        if loadedModelId == modelId, state.modelStatus == .ready,
           (whisper != nil || llama.loadedModelId == modelId) {
            return true
        }
        // Someone is already loading exactly this model → await their result.
        if let task = loadTask, loadingModelId == modelId {
            return await task.value
        }
        // A load for a different model is running → cancel it, we win.
        if loadTask != nil, loadingModelId != modelId {
            loadTask?.cancel()
            loadTask = nil
        }
        loadingModelId = modelId
        // Transcriber is @MainActor and lives for the whole app lifetime, so
        // this Task runs on the MainActor and needs no weak capture.
        let task = Task { () -> Bool in
            let ok = await self.load(modelId: modelId)
            if self.loadingModelId == modelId {
                self.loadTask = nil
                self.loadingModelId = nil
            }
            return ok
        }
        loadTask = task
        return await task.value
    }

    private func beginLoadProgress(_ label: String) {
        state.isLoadingModel = true
        state.modelLoadProgress = 0.05
        state.modelLoadPhase = "Preparing \(label)…"
        state.modelStatus = .loading
        state.statusMessage = "Loading \(label)…"
    }

    private func endLoadProgress(success: Bool) {
        state.isLoadingModel = false
        state.modelLoadProgress = success ? 1.0 : 0
        state.modelLoadPhase = ""
    }

    /// Maps WhisperKit's coarse `ModelState` to a stepped 0…1 bar + phrase.
    /// Static + MainActor so it can be called from the `@Sendable` state
    /// callback without capturing the (non-Sendable) Transcriber.
    @MainActor
    static func reportModelState(_ s: ModelState, label: String) {
        let st = AppState.shared
        guard st.isLoadingModel else { return }
        let (p, phrase): (Double, String)
        switch s {
        case .downloading:            (p, phrase) = (0.10, "Downloading \(label)…")
        case .downloaded:             (p, phrase) = (0.25, "Preparing \(label)…")
        case .prewarming:             (p, phrase) = (0.45, "Specializing for the Neural Engine…")
        case .prewarmed:              (p, phrase) = (0.70, "Almost ready…")
        case .loading:                (p, phrase) = (0.82, "Loading \(label) into memory…")
        case .loaded:                 (p, phrase) = (1.00, "Ready")
        case .unloading, .unloaded:   (p, phrase) = (st.modelLoadProgress, st.modelLoadPhase)
        }
        if p >= st.modelLoadProgress {
            st.modelLoadProgress = p
            st.modelLoadPhase = phrase
        }
    }

    private func load(modelId: String) async -> Bool {
        if LlamaModelOption.isLlamaId(modelId) {
            return await loadLlama(modelId: modelId)
        }
        let label = WhisperModelOption.find(id: modelId).display
        fputs("NotchWhisper: loading model \(label) (\(modelId))...\n", stderr)
        beginLoadProgress(label)

        // Switching away from the llama engine: free its weights first.
        if llama.loadedModelId != nil { llama.unload() }

        // Tear down any previously-loaded model first so a stale instance for a
        // different variant can never be observed as "ready" after a switch.
        if let old = whisper, loadedModelId != modelId {
            await old.unloadModels()
        }
        whisper = nil
        loadedModelId = nil

        let token = Keychain.getToken()

        // Custom HF repo model ("<repoId>:<folder>"): load straight from that
        // folder — it was already downloaded via the Find Models tab.
        if let custom = WhisperModelOption.parseCustom(modelId) {
            guard let folderURL = findModelFolder(named: custom.folder) else {
                state.modelStatus = .error("Custom model folder '\(custom.folder)' not found on disk.")
                state.statusMessage = "Custom model not found."
                return false
            }
            return await loadFolder(
                folderURL, modelId: modelId, label: label, token: tokenIfGated(custom.repo)
            )
        }

        // Offline-first for catalog models: WhisperKit's download path
        // (setupModels → download(variant:)) ALWAYS queries the Hugging Face
        // hub for the file list before looking at disk, so a model that is
        // already fully downloaded would still fail to load with no network.
        // When the folder is on disk with complete weights, load it directly
        // (same as custom models) and only hit the network when it isn't.
        let folderName = WhisperModelOption.find(id: modelId).folderName
        if let local = localCatalogModelFolder(named: folderName) {
            fputs("NotchWhisper: using on-disk model \(folderName) (offline load)\n", stderr)
            return await loadFolder(local, modelId: modelId, label: label, token: token)
        }

        let variant = WhisperModelOption.bareId(modelId)

        let cfg = WhisperKitConfig(
            model: variant,
            downloadBase: modelDir,
            modelToken: token,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: false,
            download: true
        )
        return await construct(cfg, modelId: modelId, label: label, origin: "hub")
    }

    /// Loads a model folder directly from disk with `download: false` — the
    /// only WhisperKit path that performs zero network requests. Shared by
    /// custom-repo models and the offline-first catalog load.
    private func loadFolder(_ folderURL: URL, modelId: String, label: String, token: String?) async -> Bool {
        // `downloadBase` MUST be set even though nothing is downloaded here:
        // WhisperKit derives `tokenizerFolder` from it, and without it the
        // tokenizer cache under Models/models/openai/<variant>/ is never
        // found, so loading falls back to a hub download — which hangs or
        // fails on an offline machine.
        let cfg = WhisperKitConfig(
            model: nil,
            downloadBase: modelDir,
            modelToken: token,
            modelFolder: folderURL.path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: false,
            download: false
        )
        return await construct(cfg, modelId: modelId, label: label, origin: folderURL.path)
    }

    /// Builds the WhisperKit pipeline and drives `loadModels()` explicitly so
    /// the stepped load-progress bar (req 3) reflects real phases. Shared by
    /// the hub and offline-folder paths.
    private func construct(_ cfg: WhisperKitConfig, modelId: String, label: String, origin: String) async -> Bool {
        do {
            let w = try await WhisperKit(cfg)
            w.modelStateCallback = { _, new in
                Task { @MainActor in Transcriber.reportModelState(new, label: label) }
            }
            if Task.isCancelled { endLoadProgress(success: false); return false }
            state.modelLoadProgress = max(state.modelLoadProgress, 0.35)
            state.modelLoadPhase = "Loading \(label)…"
            // `load: false` above → weights aren't resident yet; do it here so
            // the callback fires prewarming → loading → loaded in order.
            try await w.loadModels()
            if Task.isCancelled { endLoadProgress(success: false); return false }
            whisper = w
            loadedModelId = modelId
            state.modelStatus = .ready
            endLoadProgress(success: true)
            state.statusMessage = ""
            fputs("NotchWhisper: model \(label) loaded OK from \(origin)\n", stderr)
            return true
        } catch {
            if Task.isCancelled {
                endLoadProgress(success: false)
                return false
            }
            state.modelStatus = .error(error.localizedDescription)
            state.statusMessage = error.localizedDescription
            endLoadProgress(success: false)
            fputs("NotchWhisper: model load FAILED: \(error)\n", stderr)
            return false
        }
    }

    // MARK: - llama.cpp / Qwen3-ASR engine

    /// Load a `llama:*` GGUF Qwen3-ASR model. Requires both GGUF files already
    /// on disk (downloaded from the Models tab). Tears down WhisperKit first.
    private func loadLlama(modelId: String) async -> Bool {
        guard let opt = LlamaModelOption.find(id: modelId) else {
            state.modelStatus = .error("Unknown Qwen3-ASR model '\(modelId)'.")
            state.statusMessage = "Unknown model."
            return false
        }
        let label = opt.display
        fputs("NotchWhisper: loading model \(label) (\(modelId))...\n", stderr)
        beginLoadProgress(label)

        guard GGUFDownloader.isDownloaded(opt) else {
            state.modelStatus = .error("\(label) isn't downloaded yet.")
            state.statusMessage = "Download \(label) first."
            endLoadProgress(success: false)
            return false
        }

        // Tear down WhisperKit so a stale instance can't be observed as ready.
        if let old = whisper { await old.unloadModels() }
        whisper = nil
        loadedModelId = nil

        let modelPath = GGUFDownloader.modelPath(for: opt).path
        let mmprojPath = GGUFDownloader.mmprojPath(for: opt).path
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

        do {
            try await llama.load(
                modelId: modelId, modelPath: modelPath, mmprojPath: mmprojPath, threads: threads
            ) { p, phase in
                Task { @MainActor in
                    guard AppState.shared.isLoadingModel else { return }
                    if p >= AppState.shared.modelLoadProgress {
                        AppState.shared.modelLoadProgress = p
                        AppState.shared.modelLoadPhase = phase
                    }
                }
            }
            if Task.isCancelled { llama.unload(); endLoadProgress(success: false); return false }
            loadedModelId = modelId
            state.modelStatus = .ready
            endLoadProgress(success: true)
            state.statusMessage = ""
            fputs("NotchWhisper: model \(label) loaded OK (llama.cpp)\n", stderr)
            return true
        } catch {
            state.modelStatus = .error(error.localizedDescription)
            state.statusMessage = error.localizedDescription
            endLoadProgress(success: false)
            fputs("NotchWhisper: llama model load FAILED: \(error)\n", stderr)
            return false
        }
    }

    /// True when the active engine is llama.cpp / Qwen3-ASR (hold-to-talk only).
    var activeEngineIsLlama: Bool { LlamaModelOption.isLlamaId(loadedModelId ?? "") }

    /// llama.cpp GGUF Qwen3-ASR models present on disk (by model id).
    func availableLocalLlamaModelIds() -> [String] {
        LlamaModelOption.all.filter { GGUFDownloader.isDownloaded($0) }.map(\.id)
    }

    /// Builds the Qwen3-ASR "context" system prompt: a language hint plus a few
    /// dictionary terms as hotwords. Qwen3-ASR is trained to use this text.
    private func llamaContextPrompt(biasTerms: [String]) -> String {
        var lines: [String] = []
        if let lang = settings.language, !lang.isEmpty, lang.lowercased() != "auto" {
            lines.append("Language: \(lang).")
        }
        let terms = biasTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40)
        if !terms.isEmpty {
            lines.append("Expected terms: " + terms.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: " ")
    }

    /// Locates the on-disk folder of a catalog model, requiring complete
    /// CoreML weights. Checks the canonical WhisperKit layout first
    /// (`models/argmaxinc/whisperkit-coreml/<folderName>`), then scans the
    /// whole model dir for older/alternate layouts.
    private func localCatalogModelFolder(named folderName: String) -> URL? {
        let canonical = modelDir
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc/whisperkit-coreml")
            .appendingPathComponent(folderName, isDirectory: true)
        if hasModelWeightsInFolder(canonical) { return canonical }
        guard let en = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let url as URL in en where url.lastPathComponent == folderName {
            if hasModelWeightsInFolder(url) { return url }
        }
        return nil
    }

    /// Whether a custom-repo model folder exists on disk AND is complete
    /// (carries real CoreML weights). Deliberately strict: a folder created
    /// mid-download (metadata files only) must not read as "Downloaded".
    func hasLocalModelFolder(_ folder: String) -> Bool {
        guard let en = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let url as URL in en where url.lastPathComponent == folder {
            if hasModelWeightsInFolder(url) { return true }
        }
        return false
    }

    /// Recursively search the model dir for a subfolder named `folder` that
    /// contains CoreML weights (WhisperKit nests by org/repo).
    private func findModelFolder(named folder: String) -> URL? {
        guard let en = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var best: URL?
        for case let url as URL in en {
            guard url.lastPathComponent == folder,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            best = url
            if hasModelWeightsInFolder(url) { return url }
        }
        return best
    }

    /// Only gated repos need a token; harmless to pass one otherwise.
    private func tokenIfGated(_ repo: String) -> String? { Keychain.getToken() }

    func transcribe(_ samples: [Float], biasTerms: [String] = []) async throws -> String {
        if activeEngineIsLlama {
            return try await llama.transcribe(
                samples, context: llamaContextPrompt(biasTerms: biasTerms)
            )
        }
        let segments = try await decode(samples, biasTerms: biasTerms)
        return segments.map { $0.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines as CharacterSet)
    }

    /// Transcribe a whole imported FILE (Upload page).
    ///
    /// Same engines as dictation, but built for clips that can run for hours:
    ///  · progress is reported over the clip (0…1) as segments are discovered,
    ///  · the run can be cancelled mid-file (`isCancelled` is polled by the
    ///    engine callbacks, so a cancel takes effect within one window),
    ///  · timestamps stay ON so segment ends can drive that progress, and
    ///    long-form decoding keeps its window alignment.
    ///
    /// `onProgress` / `isCancelled` are called off the MainActor — callers hop
    /// themselves.
    func transcribeFile(
        _ samples: [Float],
        biasTerms: [String] = [],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        if activeEngineIsLlama {
            return try await llama.transcribe(
                samples,
                context: llamaContextPrompt(biasTerms: biasTerms),
                isCancelled: isCancelled,
                onProgress: onProgress
            )
        }
        guard let w = whisper else { throw TranscriberError.notLoaded }

        var initialPrompt: [Int]?
        if !biasTerms.isEmpty, let tok = w.tokenizer {
            var ids: [Int] = []
            for term in biasTerms {
                let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                ids.append(contentsOf: tok.encode(text: t))
            }
            if ids.count > 100 { ids = Array(ids.prefix(100)) }
            if !ids.isEmpty { initialPrompt = ids }
        }

        let totalSeconds = max(0.001, Double(samples.count) / Double(WhisperKit.sampleRate))
        let opts = DecodingOptions(
            verbose: false,
            task: settings.task == "translate" ? .translate : .transcribe,
            language: settings.language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,   // segment ends drive the progress bar
            promptTokens: initialPrompt
        )
        let results = try await w.transcribe(
            audioArray: samples,
            decodeOptions: opts,
            // Returning `false` aborts the decode loop — that's how a cancel
            // reaches WhisperKit from the UI.
            callback: { _ in isCancelled() ? false : nil },
            segmentCallback: { segments in
                guard let end = segments.last?.end else { return }
                onProgress(min(1, max(0, Double(end) / totalSeconds)))
            }
        )
        if isCancelled() { throw CancellationError() }
        return results
            .flatMap { $0.segments }
            .map { $0.text }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines as CharacterSet)
    }

    /// Fast, incremental real-time dictation decode. Transcribes only `samples`
    /// (a short ~1–2 s chunk) and uses the already-transcribed `runningText` as
    /// a prefill prompt so the model continues the sentence naturally without
    /// re-reading earlier audio. Uses a single greedy decode (no temperature
    /// fallbacks) — each pass is cheap so words can stream out as you speak.
    func liveTranscribeChunk(_ samples: [Float], runningText: String, biasTerms: [String] = []) async throws -> String {
        if activeEngineIsLlama { throw TranscriberError.liveUnsupported }
        guard let w = whisper else { throw TranscriberError.notLoaded }

        // Prompt context: recent already-transcribed text (capped so the token
        // budget stays bounded) + a few dictionary terms for bias.
        var ids: [Int] = []
        if let tok = w.tokenizer {
            let context = String(runningText.suffix(120))
            if !context.isEmpty {
                ids.append(contentsOf: tok.encode(text: context))
            }
            let bias = DictionaryStore.shared.biasingTerms()
            for term in bias {
                let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                ids.append(contentsOf: tok.encode(text: t))
            }
        }
        // Cap the total prompt to Whisper's practical budget.
        if ids.count > 200 { ids = Array(ids.suffix(200)) }

        let opts = DecodingOptions(
            verbose: false,
            task: settings.task == "translate" ? .translate : .transcribe,
            language: settings.language,
            temperature: 0.0,
            temperatureFallbackCount: 0,   // single greedy pass → fast, low-latency
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: ids.isEmpty ? nil : ids
        )
        let results = try await w.transcribe(audioArray: samples, decodeOptions: opts)
        return results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines as CharacterSet)
    }

    /// Shared decode for hold-to-talk: bias the engine with dictionary terms and
    /// run Whisper over the whole utterance (timestamps folded away).
    private func decode(_ samples: [Float], biasTerms: [String]) async throws -> [TranscriptionSegment] {
        guard let w = whisper else { throw TranscriberError.notLoaded }

        // Bias the engine: feed dictionary terms as an initial prompt so it
        // leans toward producing them. This is a nudge, not a guarantee — the
        // correction pass (run afterward) is the guaranteed path.
        var initialPrompt: [Int]?
        if !biasTerms.isEmpty, let tok = w.tokenizer {
            var ids: [Int] = []
            for term in biasTerms {
                let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                ids.append(contentsOf: tok.encode(text: t))
            }
            // Cap to a small budget to avoid drift on quiet audio.
            if ids.count > 100 { ids = Array(ids.prefix(100)) }
            if !ids.isEmpty { initialPrompt = ids }
        }

        let opts = DecodingOptions(
            verbose: false,
            task: settings.task == "translate" ? .translate : .transcribe,
            language: settings.language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: initialPrompt
        )
        let results = try await w.transcribe(audioArray: samples, decodeOptions: opts)
        return results.flatMap { $0.segments }
    }

    /// Live-dictation decode over a SHORT recent window. Single greedy pass
    /// (no temperature fallbacks) for low latency, timestamps ON so segments
    /// carry real audio positions (the confirmation logic in LiveTranscriber
    /// needs them), dictionary bias as a prefill prompt.
    func liveTranscribe(_ samples: [Float], biasTerms: [String] = []) async throws -> [TranscriptionSegment] {
        if activeEngineIsLlama { throw TranscriberError.liveUnsupported }
        guard let w = whisper else { throw TranscriberError.notLoaded }

        // Short bias prompt only: a long prefill on a short window makes
        // Whisper invent text on quiet audio (see skill: cap ~100 tokens).
        var initialPrompt: [Int]?
        if !biasTerms.isEmpty, let tok = w.tokenizer {
            var ids: [Int] = []
            for term in biasTerms {
                let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                ids.append(contentsOf: tok.encode(text: t))
            }
            if ids.count > 100 { ids = Array(ids.prefix(100)) }
            if !ids.isEmpty { initialPrompt = ids }
        }

        let opts = DecodingOptions(
            verbose: false,
            task: settings.task == "translate" ? .translate : .transcribe,
            language: settings.language,
            temperature: 0.0,
            temperatureFallbackCount: 0,   // single greedy pass → fast, low-latency
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,      // timestamps REQUIRED for confirmation
            promptTokens: initialPrompt
        )
        let results = try await w.transcribe(audioArray: samples, decodeOptions: opts)
        return results.flatMap { $0.segments }
    }

    /// Download a model from Hugging Face without switching the active model.
    ///
    /// Robustness (the "download never completes" fix):
    ///  1. Sweep stale partial downloads first — a half-downloaded model
    ///     folder (config files without the CoreML weights) or orphaned
    ///     `.incomplete` files make WhisperKit think content exists and can
    ///     poison later loads. Found exactly this on this machine.
    ///  2. Retry the whole snapshot up to `maxAttempts` times with backoff —
    ///     one network hiccup (VPN/tunnel switch) no longer kills the
    ///     download. WhisperKit's per-file downloader already resumes via
    ///     HTTP Range and keeps `.incomplete` state between attempts.
    ///  3. Stall watchdog: if progress hasn't advanced for 45 s the attempt
    ///     is cancelled and retried, instead of sitting at 47% forever.
    func download(modelId: String) async -> Bool {
        if let llamaOpt = LlamaModelOption.find(id: modelId) {
            return await GGUFDownloader.download(llamaOpt)
        }
        let option = WhisperModelOption.find(id: modelId)
        let label = option.display
        state.isDownloading = true
        state.downloadingModelId = modelId
        state.downloadProgress = 0
        state.downloadLabel = "Preparing \(label)…"
        state.resetDownloadStats()
        // Byte-accurate stats: sample the on-disk folder (plus WhisperKit's
        // `.cache/huggingface/download` staging area) while it downloads. The
        // total is estimated from the catalog size label; WhisperKit's own
        // progress is file-count based and can't express "1.1 GB of 2.0 GB".
        let repoRoot = modelDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
        // Exact total from the HF API when available (cached), else the
        // catalog's rough label. The label was off by 2–3× for several tiers,
        // which made the percentage and "X MB / Y MB" line wrong (req 5).
        ModelCatalog.shared.refreshIfNeeded()
        let realTotal = ModelCatalog.shared.downloadTotalBytes(for: option)
        let sampler = startDownloadStatsSampler(
            repoRoot: repoRoot,
            folder: option.folderName,
            totalBytes: realTotal
        )
        defer {
            sampler.cancel()
            state.isDownloading = false
            state.downloadingModelId = nil
            state.downloadLabel = ""
        }

        cleanPartialDownloads()

        let token = Keychain.getToken()
        let variant = WhisperModelOption.bareId(modelId)

        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            // Progress resumes from whatever files already completed.
            await MainActor.run {
                AppState.shared.downloadProgress = 0
                AppState.shared.downloadBytesDone = 0
                AppState.shared.downloadLabel = attempt == 1
                    ? "Downloading \(label)…"
                    : "Retrying \(label) (attempt \(attempt)/\(maxAttempts))…"
            }
            // Watchdog: cancel the attempt if progress freezes for 45 s.
            let lastProgress = ProgressBox(0, Date())
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    let (value, at) = await lastProgress.get()
                    if Date().timeIntervalSince(at) > 45, value < 0.999 {
                        await lastProgress.cancelStalled()
                        return
                    }
                }
            }

            do {
                // Run the download in a dedicated task so the watchdog can
                // CANCEL it on a stall: WhisperKit's downloader installs a
                // cancellation handler that stops the transfer (per-file
                // resume state is kept for the next attempt).
                let downloadTask = Task {
                    try await WhisperKit.download(
                        variant: variant,
                        downloadBase: modelDir,
                        token: token
                    ) { progress in
                        let f = progress.fractionCompleted
                        // Sync (non-async) callback: hop via tasks. The UI
                        // update is monotonic so out-of-order hops are safe.
                        Task { @MainActor in
                            let p = AppState.shared.downloadProgress
                            if f > p { AppState.shared.downloadProgress = f }
                        }
                        Task { await lastProgress.update(f) }
                    }
                }
                // Watchdog side-channel: when it detects a stall it cancels
                // `downloadTask`, which makes `downloadTask.value` throw.
                await lastProgress.setTarget(downloadTask)
                _ = try await downloadTask.value
                watchdog.cancel()
                // Ensure the finished folder carries the CoreML weights —
                // guards against a silent partial completion.
                guard hasModelWeights(folderName: WhisperModelOption.find(id: modelId).folderName) else {
                    throw TranscriberError.downloadIncomplete
                }
                await MainActor.run {
                    AppState.shared.downloadProgress = 1.0
                    if AppState.shared.downloadBytesTotal > 0 {
                        AppState.shared.downloadBytesDone = AppState.shared.downloadBytesTotal
                    }
                }
                fputs("NotchWhisper: download of \(label) completed\n", stderr)
                return true
            } catch {
                lastError = error
                watchdog.cancel()
                fputs("NotchWhisper: download attempt \(attempt) failed: \(error)\n", stderr)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
                }
            }
        }
        await MainActor.run {
            AppState.shared.showToast("Download failed after \(maxAttempts) attempts: \(lastError?.localizedDescription ?? "unknown error")")
        }
        return false
    }

    /// Whether the on-disk folder for `folderName` carries complete CoreML
    /// weights — same strictness as the UI's "Downloaded" detection, so a
    /// silent partial completion can't be reported as success.
    private func hasModelWeights(folderName: String) -> Bool {
        let base = modelDir
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc/whisperkit-coreml")
            .appendingPathComponent(folderName, isDirectory: true)
        return hasModelWeightsInFolder(base)
    }

    /// Removes model folders that never finished downloading (config files
    /// present, CoreML weights missing) and orphaned `.incomplete` files.
    /// Only touches folders matching known catalog entries — never `.cache`
    /// metadata of healthy downloads.
    private func cleanPartialDownloads() {
        let known = Set(WhisperModelOption.all.map { $0.folderName })
        let roots = [
            modelDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml"),
            modelDir.appendingPathComponent("models/openai"),
        ]
        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for item in contents {
                guard item.lastPathComponent != ".cache" else { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir, known.contains(item.lastPathComponent) else { continue }
                if !hasModelWeightsInFolder(item) {
                    fputs("NotchWhisper: removing partial download \(item.path)\n", stderr)
                    try? fileManager.removeItem(at: item)
                }
            }
        }
        // Orphaned .incomplete files (the downloader's own resume state is
        // keyed by etag and recreated as needed).
        if let en = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.lastPathComponent.hasSuffix(".incomplete") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func hasModelWeightsInFolder(_ folder: URL) -> Bool {
        // Only real CoreML weight data counts. Directory NAMES appear as soon
        // as a bundle's small metadata files (model.mil, metadata.json, …)
        // finish downloading — long before the big weights land — so a
        // name-only check made in-progress downloads read as "Downloaded".
        //
        // Completeness = each of the three compiled bundles exists AND carries
        // real weight data. Different variants lay weights out differently
        // (`weights/weight.bin`, `weights/weight.esbin`, or inline in a large
        // `coremldata.bin` for older ML-program builds), so instead of pinning
        // one path we require the bundle to hold at least ~256 KB of actual
        // file data — enough to tell "config only" (a few KB) from "has
        // weights" without assuming a layout.
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            let bundle = folder.appendingPathComponent(name, isDirectory: true)
            let weights = bundle.appendingPathComponent("weights", isDirectory: true)
            let ok = hasNonEmptyFile(weights) || bundleByteSize(bundle) >= 200 * 1024
            guard ok else { return false }
        }
        return true
    }

    /// True when `dir` contains at least one non-empty regular file.
    private func hasNonEmptyFile(_ dir: URL) -> Bool {
        guard let en = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return false }
        for case let url as URL in en {
            if let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true, (v.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    /// Sum of regular-file bytes anywhere inside a `.mlmodelc` bundle.
    private func bundleByteSize(_ dir: URL) -> Int64 {
        guard let en = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            if let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// Models already present on disk AND complete enough to load.
    ///
    /// WhisperKit downloads into `<downloadBase>/models/argmaxinc/whisperkit-coreml/<folder>`,
    /// so scan THERE (the old code scanned the top level and could only ever
    /// see the stray `models` directory). A folder counts as present only when
    /// it contains the CoreML weights — config-only partial downloads are
    /// invisible to the user instead of showing as "Downloaded".
    func availableLocalModels() -> [String] {
        let downloadRoot = modelDir
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc/whisperkit-coreml")
        guard let contents = try? fileManager.contentsOfDirectory(
            at: downloadRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        let known = Set(WhisperModelOption.all.map { $0.folderName })
        return contents
            .filter { $0.lastPathComponent != ".cache" }
            .filter { known.contains($0.lastPathComponent) }
            .filter { hasModelWeightsInFolder($0) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    enum TranscriberError: LocalizedError {
        case notLoaded, downloadIncomplete, liveUnsupported

        var errorDescription: String? {
            switch self {
            case .notLoaded:          return "The transcription model isn't loaded."
            case .downloadIncomplete: return "The model download didn't complete."
            case .liveUnsupported:    return "Live dictation isn't supported by this model — use hold-to-talk."
            }
        }
    }

    // MARK: - Download stats sampling

    /// Starts a background sampler that measures the bytes already on disk for
    /// `folder` under `repoRoot` (plus WhisperKit's `.cache/huggingface/download`
    /// staging area, where in-flight files live as `*.incomplete`) and publishes
    /// byte-accurate progress, speed and ETA to AppState until cancelled.
    ///
    /// WhisperKit's progress callback is file-count based (one unit per file,
    /// see `HubApi.snapshot`), so it cannot express "1.1 GB of 2.0 GB" — the
    /// disk sampler can. Runs every 0.7 s; disk scanning happens off-main.
    @discardableResult
    func startDownloadStatsSampler(repoRoot: URL, folder: String, totalBytes: Int64) -> Task<Void, Never> {
        Task {
            var lastBytes: Int64 = -1
            var lastAt: Date? = nil
            var speedEma: Double = 0
            while !Task.isCancelled {
                let bytes = await Task.detached(priority: .utility) {
                    Self.bytesOnDisk(repoRoot: repoRoot, folder: folder)
                }.value
                let now = Date()
                if let at = lastAt, lastBytes >= 0 {
                    let dt = now.timeIntervalSince(at)
                    if dt > 0.2 {
                        let inst = Double(bytes - lastBytes) / dt
                        // Exponential smoothing: fast to react, immune to
                        // single-sample jitter; decays toward 0 when stalled.
                        speedEma = inst > 0 ? (speedEma * 0.6 + inst * 0.4) : speedEma * 0.7
                    }
                }
                state.downloadBytesDone = bytes
                state.downloadSpeedBps = speedEma
                if totalBytes > 0 {
                    state.downloadBytesTotal = totalBytes
                    state.downloadEtaSeconds = speedEma > 1024
                        ? Double(max(0, totalBytes - bytes)) / speedEma : 0
                }
                lastBytes = bytes
                lastAt = now
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// Sum of regular-file bytes for `folder` under `repoRoot` and for the
    /// matching staging area WhisperKit downloads into. 0 when nothing exists.
    nonisolated static func bytesOnDisk(repoRoot: URL, folder: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let targets = [
            repoRoot.appendingPathComponent(folder, isDirectory: true),
            repoRoot
                .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true),
        ]
        for target in targets {
            guard let en = fm.enumerator(
                at: target, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { continue }
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true,
                      !url.lastPathComponent.hasSuffix(".metadata") else { continue }
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// Parses a catalog size label like "~140 MB" or "~1.6 GB" into bytes
    /// (0 when the label carries no parsable size).
    nonisolated static func parseSizeLabel(_ label: String) -> Int64 {
        let lowered = label.lowercased()
        let units: [(suffix: String, multiplier: Int64)] = [
            ("tb", 1024 * 1024 * 1024 * 1024),
            ("gb", 1024 * 1024 * 1024),
            ("mb", 1024 * 1024),
            ("kb", 1024),
        ]
        for unit in units {
            guard let range = lowered.range(of: unit.suffix) else { continue }
            let digits = lowered[..<range.lowerBound].compactMap { ch in
                (ch.isNumber || ch == ".") ? ch : nil
            }
            if let value = Double(String(digits)), value > 0 {
                return Int64(value * Double(unit.multiplier))
            }
        }
        return 0
    }
}

/// Tiny progress box shared between the download progress callback
/// (nonisolated) and the stall watchdog task. The watchdog reads the last
/// progress value/timestamp and, on a stall, cancels the download task so
/// the retry loop can take over.
private actor ProgressBox {
    private var value: Double
    private var updatedAt: Date
    private var target: Task<URL, any Error>?

    init(_ value: Double, _ at: Date) {
        self.value = value
        self.updatedAt = at
    }

    func update(_ v: Double) {
        if v > value { value = v }
        updatedAt = Date()
    }

    func get() -> (Double, Date) { (value, updatedAt) }

    func setTarget(_ t: Task<URL, any Error>?) { target = t }

    /// Called by the watchdog when progress has frozen: cancel the download
    /// task so `await downloadTask.value` throws and the attempt unwinds.
    func cancelStalled() {
        fputs("NotchWhisper: download stalled — cancelling attempt\n", stderr)
        target?.cancel()
    }
}
