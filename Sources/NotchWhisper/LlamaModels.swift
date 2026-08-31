import Foundation

/// A GGUF Qwen3-ASR model runnable through the llama.cpp / mtmd backend
/// (`LlamaASR`). Parallel to `WhisperModelOption`, but a llama model is always
/// two files — the decoder weights and the audio projector (`mmproj`).
///
/// Model ids are prefixed `llama:` so `Settings.modelId` stays the single
/// source of truth and `Transcriber` can route by prefix.
struct LlamaModelOption: Identifiable, Hashable {
    let id: String              // e.g. "llama:qwen3-asr-1.7b-q8"
    let display: String         // "Qwen3-ASR 1.7B"
    let quant: String           // "Q8_0" / "BF16"
    let repoId: String          // "ggml-org/Qwen3-ASR-1.7B-GGUF"
    let modelFile: String       // "Qwen3-ASR-1.7B-Q8_0.gguf"
    let mmprojFile: String      // "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"
    let sizeBytes: Int64         // model + mmproj, exact (from the HF API)
    let ramBytes: Int64          // rough resident footprint
    let minRAMGB: Int            // hardware gate
    let blurb: String
    let recommendation: String

    var id_: String { id }

    /// Human download size, e.g. "~2.5 GB".
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var ramLabel: String { ByteCountFormatter.string(fromByteCount: ramBytes, countStyle: .file) }

    // MARK: - Attribution

    /// HF handle of the model's maker (shown with their avatar on the card).
    var makerOrg: String { "Qwen" }
    var makerDisplay: String { "Qwen (Alibaba)" }
    /// The maker's base model on Hugging Face (`Qwen/Qwen3-ASR-1.7B`).
    var makerModelURL: URL {
        let base = repoId
            .replacingOccurrences(of: "ggml-org/", with: "Qwen/")
            .replacingOccurrences(of: "-GGUF", with: "")
        return URL(string: "https://huggingface.co/\(base)")!
    }
    /// The GGUF repo actually downloaded (`ggml-org/Qwen3-ASR-1.7B-GGUF`).
    var ggufURL: URL { URL(string: "https://huggingface.co/\(repoId)")! }

    /// The two HF file URLs to download.
    var fileURLs: [(name: String, url: URL, expectedBytes: Int64)] {
        [modelFile, mmprojFile].compactMap { name in
            guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(name)") else { return nil }
            return (name, url, 0)
        }
    }

    static let prefix = "llama:"
    static func isLlamaId(_ modelId: String) -> Bool { modelId.hasPrefix(prefix) }

    private static let GB: Int64 = 1_073_741_824
    private static let MB: Int64 = 1_048_576

    /// The catalog. WER/latency figures are omitted — Qwen3-ASR has no public
    /// per-model WER table and its strength is multilingual + context biasing,
    /// not a single English number.
    static let all: [LlamaModelOption] = [
        LlamaModelOption(
            id: "\(prefix)qwen3-asr-1.7b-q8",
            display: "Qwen3-ASR 1.7B",
            quant: "Q8_0",
            repoId: "ggml-org/Qwen3-ASR-1.7B-GGUF",
            modelFile: "Qwen3-ASR-1.7B-Q8_0.gguf",
            mmprojFile: "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf",
            sizeBytes: 2165 * MB + 356 * MB,
            ramBytes: 4 * GB,
            minRAMGB: 16,
            blurb: "Qwen's multilingual speech model — strong on accents, code-switching and noisy audio, and takes a context prompt for hotword biasing.",
            recommendation: "Best Qwen3-ASR accuracy. Needs 16 GB+ RAM; hold-to-talk only (live dictation stays on Whisper)."
        ),
        LlamaModelOption(
            id: "\(prefix)qwen3-asr-0.6b-q8",
            display: "Qwen3-ASR 0.6B",
            quant: "Q8_0",
            repoId: "ggml-org/Qwen3-ASR-0.6B-GGUF",
            modelFile: "Qwen3-ASR-0.6B-Q8_0.gguf",
            mmprojFile: "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf",
            sizeBytes: 805 * MB + 214 * MB,
            ramBytes: 2 * GB,
            minRAMGB: 8,
            blurb: "Lighter Qwen3-ASR — runs on 8 GB Macs and downloads fast, with most of the multilingual quality of the 1.7B.",
            recommendation: "Good Qwen3-ASR option for 8–16 GB Macs. Hold-to-talk only."
        ),
        LlamaModelOption(
            id: "\(prefix)qwen3-asr-1.7b-bf16",
            display: "Qwen3-ASR 1.7B (BF16)",
            quant: "BF16",
            repoId: "ggml-org/Qwen3-ASR-1.7B-GGUF",
            modelFile: "Qwen3-ASR-1.7B-bf16.gguf",
            mmprojFile: "mmproj-Qwen3-ASR-1.7B-bf16.gguf",
            sizeBytes: 4070 * MB + 642 * MB,
            ramBytes: 6 * GB,
            minRAMGB: 24,
            blurb: "Full-precision Qwen3-ASR 1.7B — the maximum quality build, at roughly double the download and memory of the Q8.",
            recommendation: "Only on 32 GB+ Macs where you want every last point of accuracy. Hold-to-talk only."
        ),
    ]

    static func find(id: String) -> LlamaModelOption? {
        all.first { $0.id == id }
    }
}
