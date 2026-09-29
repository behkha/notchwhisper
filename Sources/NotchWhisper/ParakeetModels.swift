import Foundation

/// A Parakeet TDT model runnable through FluidAudio (`ParakeetASR`). Parallel
/// to `WhisperModelOption` and `LlamaModelOption`.
///
/// Parakeet is NVIDIA's FastConformer encoder with a token-and-duration
/// transducer (TDT) decoder — a different architecture from Whisper, so its
/// Core ML bundles (`Preprocessor`, `Encoder`, `Decoder`, `JointDecision`) are
/// something WhisperKit cannot open. FluidInference publishes the Core ML
/// builds; FluidAudio downloads and runs them.
///
/// Model ids are prefixed `parakeet:` so `Settings.modelId` stays the single
/// source of truth and `Transcriber` can route by prefix.
struct ParakeetModelOption: Identifiable, Hashable {
    let id: String              // "parakeet:v3"
    let display: String         // "Parakeet v3"
    /// FluidAudio's `AsrModelVersion` case name. Kept as a string so this
    /// catalog doesn't have to import FluidAudio; `ParakeetASR` maps it.
    let version: String
    let repoId: String          // "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    /// Folder FluidAudio writes the repository into: the repo name minus
    /// "-coreml" (FluidAudio's `Repo.folderName`).
    let folderName: String
    let sizeBytes: Int64        // on disk after download
    /// Downloaded and run end to end through this app (not just listed).
    let verified: Bool
    let ramBytes: Int64         // rough resident footprint
    let languages: [String]
    /// LibriSpeech test-clean WER as published by the model's maintainers.
    let englishWER: Double
    let werSource: String
    let blurb: String
    let recommendation: String

    static let prefix = "parakeet:"
    static func isParakeetId(_ modelId: String) -> Bool { modelId.hasPrefix(prefix) }

    var repositoryURL: URL { URL(string: "https://huggingface.co/\(repoId)")! }

    /// Where the model lives under the storage root. One folder per model,
    /// beside WhisperKit's `models/` and the GGUF `llama/` trees.
    func dir(root: URL = ModelStorageLocation.currentRoot) -> URL {
        Self.root(root).appendingPathComponent(folderName, isDirectory: true)
    }

    static func root(_ storageRoot: URL = ModelStorageLocation.currentRoot) -> URL {
        storageRoot.appendingPathComponent("fluidaudio", isDirectory: true)
    }

    /// The 25 European languages Parakeet TDT v3 is trained on (NVIDIA model card).
    static let europeanLanguages = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    private static let MB: Int64 = 1_000_000

    /// The catalog. Sizes are the bytes FluidAudio writes: measured for v2 and
    /// v3, and for Ultra summed from the Hub listing of the files it fetches.
    static let all: [ParakeetModelOption] = [
        ParakeetModelOption(
            id: "\(prefix)ultra",
            display: "Parakeet Ultra",
            version: "ultra",
            repoId: "FluidInference/parakeet-ultra-coreml",
            folderName: "parakeet-ultra",
            sizeBytes: 632 * MB,
            verified: false,
            ramBytes: 1_200 * MB,
            languages: europeanLanguages,
            englishWER: 2.13,
            werSource: "FluidAudio benchmark (LibriSpeech test-clean)",
            blurb: "A post-trained Parakeet v3: the same 25 European languages and speed, more accurate on every one of them.",
            recommendation: "The best Parakeet. Very fast on the Neural Engine and strong on English and European languages."
        ),
        ParakeetModelOption(
            id: "\(prefix)v3",
            display: "Parakeet v3",
            version: "v3",
            repoId: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            folderName: "parakeet-tdt-0.6b-v3",
            sizeBytes: 483 * MB,
            verified: true,
            ramBytes: 1_000 * MB,
            languages: europeanLanguages,
            englishWER: 2.27,
            werSource: "FluidAudio benchmark (LibriSpeech test-clean)",
            blurb: "NVIDIA's multilingual Parakeet TDT 0.6B — 25 European languages with punctuation, transcribing a minute of audio in about half a second.",
            recommendation: "Fast, accurate multilingual dictation for European languages."
        ),
        ParakeetModelOption(
            id: "\(prefix)v2",
            display: "Parakeet v2 (English)",
            version: "v2",
            repoId: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            folderName: "parakeet-tdt-0.6b-v2",
            sizeBytes: 464 * MB,
            verified: true,
            ramBytes: 1_000 * MB,
            languages: ["en"],
            englishWER: 1.69,
            werSource: "NVIDIA model card (LibriSpeech test-clean)",
            blurb: "NVIDIA's English-only Parakeet TDT 0.6B — a tighter vocabulary with better recall on rare English words.",
            recommendation: "Best Parakeet for English-only dictation."
        ),
    ]

    static func find(id: String) -> ParakeetModelOption? {
        all.first { $0.id == id }
    }

    /// The catalog entry published from a Hugging Face repository, if any.
    static func find(repoId: String) -> ParakeetModelOption? {
        all.first { $0.repoId.caseInsensitiveCompare(repoId) == .orderedSame }
    }
}
