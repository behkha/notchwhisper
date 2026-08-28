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

    var modelDir: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/Models")
    }

    init(_ state: AppState, _ settings: Settings) {
        self.state = state
        self.settings = settings
    }

    /// Load (downloading if needed) the model selected in settings.
    func ensureLoaded() async -> Bool {
        if whisper != nil, loadedModelId == settings.modelId, state.modelStatus == .ready {
            return true
        }
        return await load(modelId: settings.modelId)
    }

    private func load(modelId: String) async -> Bool {
        let label = WhisperModelOption.find(id: modelId).display
        fputs("NotchWhisper: loading model \(label) (\(modelId))...\n", stderr)
        state.modelStatus = .loading
        state.statusMessage = "Loading \(label)…"
        let token = Keychain.getToken()
        let variant = WhisperModelOption.bareId(modelId)

        let cfg = WhisperKitConfig(
            model: variant,
            downloadBase: modelDir,
            modelToken: token,
            verbose: false,
            logLevel: .none,
            load: true
        )

        do {
            let w = try await WhisperKit(cfg)
            w.modelStateCallback = { _, new in
                if new == .loaded {
                    Task { @MainActor in AppState.shared.modelStatus = .ready }
                }
            }
            whisper = w
            loadedModelId = modelId
            state.modelStatus = .ready
            fputs("NotchWhisper: model \(label) loaded OK\n", stderr)
            return true
        } catch {
            state.modelStatus = .error(error.localizedDescription)
            state.statusMessage = error.localizedDescription
            fputs("NotchWhisper: model load FAILED: \(error)\n", stderr)
            return false
        }
    }

    func transcribe(_ samples: [Float], biasTerms: [String] = []) async throws -> String {
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
        let text = results.map { $0.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines as CharacterSet)
        return text
    }

    /// Download a model from Hugging Face without switching the active model.
    func download(modelId: String) async {
        state.isDownloading = true
        state.downloadProgress = 0
        state.downloadLabel = "Downloading \(WhisperModelOption.find(id: modelId).display)…"
        defer {
            state.isDownloading = false
            state.downloadLabel = ""
        }
        let token = Keychain.getToken()
        let variant = WhisperModelOption.bareId(modelId)
        do {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: modelDir,
                token: token
            ) { progress in
                let f = progress.fractionCompleted
                Task { @MainActor in AppState.shared.downloadProgress = f }
            }
        } catch {
            await MainActor.run {
                AppState.shared.showToast("Download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Models already present on disk (matched by full folder name).
    func availableLocalModels() -> [String] {
        let folders = WhisperModelOption.all.map { $0.folderName }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: modelDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { folders.contains($0.lastPathComponent) }
            .map { $0.lastPathComponent }
    }

    enum TranscriberError: Error { case notLoaded }
}
