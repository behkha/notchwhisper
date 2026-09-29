import Foundation
import FluidAudio

/// Parakeet TDT through FluidAudio — the third transcription engine.
///
/// Loaded only while a `parakeet:*` model (or an imported Parakeet folder) is
/// active. It runs on the Neural Engine at roughly 100× real time, which is
/// fast enough to re-decode the live-dictation window on every tick, so unlike
/// the llama.cpp engine it drives live dictation as well as hold-to-talk.
///
/// Decoding happens inside FluidAudio's `AsrManager` actor, off the main thread.
@MainActor
final class ParakeetASR {
    private var manager: AsrManager?
    private(set) var loadedModelId: String?

    enum EngineError: LocalizedError {
        case unknownVersion(String)
        case notDownloaded(String)
        case notLoaded
        case unrecognizedFolder

        var errorDescription: String? {
            switch self {
            case .unknownVersion(let v): return "This build doesn't know Parakeet version “\(v)”."
            case .notDownloaded(let name): return "\(name) isn't fully downloaded yet."
            case .notLoaded: return "The Parakeet model isn't loaded."
            case .unrecognizedFolder:
                return "That folder isn't a Parakeet model: it needs Preprocessor, Encoder, Decoder and JointDecision .mlmodelc bundles plus parakeet_vocab.json."
            }
        }
    }

    // MARK: - Versions and files

    nonisolated static func version(_ name: String) -> AsrModelVersion? {
        switch name {
        case "v2":    return .v2
        case "v3":    return .v3
        case "ultra": return .ultra
        case "redux": return .redux
        default:      return nil
        }
    }

    /// True when every file FluidAudio needs for this catalog model is on disk.
    nonisolated static func isDownloaded(_ option: ParakeetModelOption,
                                         root: URL = ModelStorageLocation.currentRoot) -> Bool {
        guard let version = version(option.version) else { return false }
        return AsrModels.modelsExist(at: option.dir(root: root), version: version)
    }

    /// Which Parakeet contract a folder of compiled bundles follows, or nil
    /// when it isn't a Parakeet model at all. v3, Ultra and Redux share the
    /// `JointDecisionv3` contract; v2 ships the plain `JointDecision`.
    nonisolated static func detectVersion(in folder: URL) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        let core = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "parakeet_vocab.json"]
        guard core.allSatisfy(has) else { return nil }
        if has("JointDecisionv3.mlmodelc") { return "v3" }
        if has("JointDecision.mlmodelc") { return "v2" }
        return nil
    }

    // MARK: - Download

    /// Fetch a catalog model into its folder under the storage root.
    ///
    /// FluidAudio's downloader streams into `.partial` files with HTTP Range,
    /// so a cancelled (paused) transfer resumes where it stopped. FluidAudio's
    /// own fraction restarts for each bundle it loads, so it isn't a usable
    /// bar — callers measure bytes on disk instead. `onCompiling` fires once
    /// the bytes are in and Core ML starts specializing the model for this Mac.
    nonisolated static func download(
        _ option: ParakeetModelOption,
        root: URL,
        onCompiling: @escaping @Sendable () -> Void
    ) async throws {
        guard let version = version(option.version) else {
            throw EngineError.unknownVersion(option.version)
        }
        try await AsrModels.download(to: option.dir(root: root), version: version) { progress in
            if case .compiling = progress.phase { onCompiling() }
        }
    }

    // MARK: - Load

    /// Load a catalog model from disk. Never downloads: `AsrModels.load`
    /// fetches anything missing, so completeness is checked first and a
    /// half-downloaded model fails here instead of silently hitting the network.
    func load(_ option: ParakeetModelOption, root: URL = ModelStorageLocation.currentRoot) async throws {
        guard let version = Self.version(option.version) else {
            throw EngineError.unknownVersion(option.version)
        }
        let dir = option.dir(root: root)
        guard AsrModels.modelsExist(at: dir, version: version) else {
            throw EngineError.notDownloaded(option.display)
        }
        unload()
        let models = try await AsrModels.load(from: dir, version: version)
        try await install(models, modelId: option.id)
    }

    /// Load a Parakeet folder the user imported. `loadLocal` reads exactly that
    /// directory — whatever it is called — and never touches the network.
    func loadFolder(_ folder: URL, modelId: String) async throws {
        guard let name = Self.detectVersion(in: folder), let version = Self.version(name) else {
            throw EngineError.unrecognizedFolder
        }
        unload()
        let models = try await Task.detached(priority: .userInitiated) {
            try AsrModels.loadLocal(from: folder, version: version)
        }.value
        try await install(models, modelId: modelId)
    }

    private func install(_ models: AsrModels, modelId: String) async throws {
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
        loadedModelId = modelId
    }

    func unload() {
        guard let m = manager else { return }
        manager = nil
        loadedModelId = nil
        Task { await m.cleanup() }
    }

    // MARK: - Transcribe

    /// Transcribe one utterance or window. Returns the text plus sentence-sized
    /// segments timed relative to the start of `samples` (see
    /// `EngineSegment.group` for `splitAt`).
    ///
    /// `languageCode` narrows v3's multilingual vocabulary to the language's
    /// script (it stops Polish drifting into Cyrillic, for example); v2 ignores it.
    func transcribe(_ samples: [Float], languageCode: String?,
                    splitAt: Double? = nil) async throws -> (text: String, segments: [EngineSegment]) {
        guard let m = manager else { throw EngineError.notLoaded }
        let language = languageCode.flatMap { Language(rawValue: $0.lowercased()) }
        var state = TdtDecoderState.make()
        let result = try await m.transcribe(samples, decoderState: &state, language: language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = (result.tokenTimings ?? []).map { (text: $0.token, start: $0.startTime, end: $0.endTime) }
        var segments = EngineSegment.group(tokens, splitAt: splitAt)
        // No timings (an empty or very short decode): the whole window is one span.
        if segments.isEmpty, !text.isEmpty {
            segments = [EngineSegment(start: 0, end: Double(samples.count) / 16_000, text: text)]
        }
        return (text, segments)
    }

    /// Long-form transcription for files and meetings. FluidAudio chunks the
    /// audio itself (15 s windows with overlap); its progress stream drives
    /// `onProgress`. The decode can't be interrupted midway, so a cancel is
    /// honoured as soon as it returns — about half a second per minute of audio.
    func transcribeLong(
        _ samples: [Float],
        languageCode: String?,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (text: String, segments: [EngineSegment]) {
        guard let m = manager else { throw EngineError.notLoaded }
        let stream = await m.transcriptionProgressStream
        let watcher = Task.detached {
            do {
                for try await p in stream { onProgress(min(1, max(0, p))) }
            } catch {}
        }
        defer { watcher.cancel() }
        let out = try await transcribe(samples, languageCode: languageCode)
        if isCancelled() { throw CancellationError() }
        onProgress(1)
        return out
    }
}
