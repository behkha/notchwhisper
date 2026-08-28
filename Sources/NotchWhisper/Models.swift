import Foundation

/// A Whisper model that can be downloaded from Hugging Face (argmaxinc/whisperkit-coreml).
///
/// IMPORTANT: WhisperKit's `download(variant:)` expects the BARE variant name
/// (e.g. "whisper-base"), and it prepends the "openai_"/"distil-whisper_" prefix
/// itself when searching the repo. So `id` here is the bare variant, while
/// `folderName` is the full on-disk folder name (used for the UI / disk checks).
///
/// Each option now carries real-world accuracy (Word Error Rate) and speed
/// (real-time factor, relative to large-v3) so the Models grid can help the user
/// pick. Figures are approximate averages across the Whisper paper, Hugging Face
/// model cards (LibriSpeech test-clean for English) and common Mac benchmarks;
/// real-world accuracy varies by audio quality, accent and language.
struct WhisperModelOption: Identifiable, Hashable {
    let id: String          // bare variant, e.g. "whisper-base"
    let display: String     // human label, e.g. "base"
    let size: String        // approximate download size
    let quality: String     // short tag: Fast / Balanced / Accurate / Best
    let folderName: String  // full HF folder name, e.g. "openai_whisper-base"

    // MARK: - Decision helper data (req 6 & 7)
    let params: String      // parameter count, e.g. "74M"
    let ram: String         // approx runtime RAM on Apple Silicon
    let englishWER: String  // English Word Error Rate (lower is better)
    let englishWERValue: Double  // numeric, for the accuracy bar (lower = better)
    let multiWER: String    // Multilingual WER, or "—" for English-only models
    let speedLabel: String  // human speed, e.g. "~7× faster"
    let speedFactor: Double // numeric real-time factor vs large (higher = faster)
    let lang: String        // "Multilingual" or "English only"
    let englishOnly: Bool
    let blurb: String       // one-line description for the card
    let recommendation: String  // when to pick this model

    /// Recommended default for most Macs.
    static let `default` = WhisperModelOption(
        id: "whisper-base", display: "base", size: "~140 MB",
        quality: "Balanced", folderName: "openai_whisper-base",
        params: "74M", ram: "~390 MB",
        englishWER: "~5.0%", englishWERValue: 5.0,
        multiWER: "~10%", speedLabel: "~7× faster", speedFactor: 7,
        lang: "Multilingual", englishOnly: false,
        blurb: "A solid balance of speed and accuracy for everyday multilingual dictation.",
        recommendation: "Good default for most people — fast and accurate enough."
    )

    /// Every model published in argmaxinc/whisperkit-coreml. The `id` is the bare
    /// variant passed to WhisperKit; `folderName` is the full repo folder.
    static let all: [WhisperModelOption] = [
        WhisperModelOption(
            id: "whisper-tiny", display: "tiny", size: "~75 MB",
            quality: "Fast", folderName: "openai_whisper-tiny",
            params: "39M", ram: "~270 MB",
            englishWER: "~7.6%", englishWERValue: 7.6,
            multiWER: "~12%", speedLabel: "~10× faster", speedFactor: 10,
            lang: "Multilingual", englishOnly: false,
            blurb: "Smallest model — near-instant, but noticeably less accurate.",
            recommendation: "Pick only when speed is everything and rough text is fine."
        ),
        WhisperModelOption(
            id: "whisper-tiny.en", display: "tiny.en", size: "~75 MB",
            quality: "Fast", folderName: "openai_whisper-tiny.en",
            params: "39M", ram: "~270 MB",
            englishWER: "~7.0%", englishWERValue: 7.0,
            multiWER: "—", speedLabel: "~10× faster", speedFactor: 10,
            lang: "English only", englishOnly: true,
            blurb: "English-only tiny. A touch better English than the multilingual tiny.",
            recommendation: "Quick English notes where accuracy isn't critical."
        ),
        WhisperModelOption(
            id: "whisper-base", display: "base", size: "~140 MB",
            quality: "Balanced", folderName: "openai_whisper-base",
            params: "74M", ram: "~390 MB",
            englishWER: "~5.0%", englishWERValue: 5.0,
            multiWER: "~10%", speedLabel: "~7× faster", speedFactor: 7,
            lang: "Multilingual", englishOnly: false,
            blurb: "A solid balance of speed and accuracy for everyday multilingual dictation.",
            recommendation: "Good default for most people — fast and accurate enough."
        ),
        WhisperModelOption(
            id: "whisper-base.en", display: "base.en", size: "~140 MB",
            quality: "Balanced", folderName: "openai_whisper-base.en",
            params: "74M", ram: "~390 MB",
            englishWER: "~4.5%", englishWERValue: 4.5,
            multiWER: "—", speedLabel: "~7× faster", speedFactor: 7,
            lang: "English only", englishOnly: true,
            blurb: "English-only base. Better English than the multilingual base.",
            recommendation: "English-only everyday dictation, a bit sharper than base."
        ),
        WhisperModelOption(
            id: "whisper-small", display: "small", size: "~470 MB",
            quality: "Balanced", folderName: "openai_whisper-small",
            params: "244M", ram: "~850 MB",
            englishWER: "~3.4%", englishWERValue: 3.4,
            multiWER: "~7%", speedLabel: "~4× faster", speedFactor: 4,
            lang: "Multilingual", englishOnly: false,
            blurb: "Where Whisper starts to feel genuinely accurate; handles accents and noise well.",
            recommendation: "Best all-rounder on 16 GB+ Macs — accuracy without the wait."
        ),
        WhisperModelOption(
            id: "whisper-small.en", display: "small.en", size: "~470 MB",
            quality: "Balanced", folderName: "openai_whisper-small.en",
            params: "244M", ram: "~850 MB",
            englishWER: "~3.0%", englishWERValue: 3.0,
            multiWER: "—", speedLabel: "~4× faster", speedFactor: 4,
            lang: "English only", englishOnly: true,
            blurb: "English-only small — excellent English accuracy at a friendly size.",
            recommendation: "Best English-only balance on most laptops."
        ),
        WhisperModelOption(
            id: "whisper-small.en_217MB", display: "small.en (217MB)", size: "~217 MB",
            quality: "Balanced", folderName: "openai_whisper-small.en_217MB",
            params: "244M (quantized)", ram: "~550 MB",
            englishWER: "~3.2%", englishWERValue: 3.2,
            multiWER: "—", speedLabel: "~4× faster", speedFactor: 4,
            lang: "English only", englishOnly: true,
            blurb: "Quantized English small — smaller download and lower RAM, nearly the same accuracy.",
            recommendation: "Space-saving English pick for 8 GB Macs."
        ),
        WhisperModelOption(
            id: "whisper-medium", display: "medium", size: "~1.5 GB",
            quality: "Accurate", folderName: "openai_whisper-medium",
            params: "769M", ram: "~2.1 GB",
            englishWER: "~2.9%", englishWERValue: 2.9,
            multiWER: "~5%", speedLabel: "~2× faster", speedFactor: 2,
            lang: "Multilingual", englishOnly: false,
            blurb: "High accuracy with strong multilingual support; comfortable on 16 GB+ Macs.",
            recommendation: "High accuracy that still finishes in roughly real time."
        ),
        WhisperModelOption(
            id: "whisper-medium.en", display: "medium.en", size: "~1.5 GB",
            quality: "Accurate", folderName: "openai_whisper-medium.en",
            params: "769M", ram: "~2.1 GB",
            englishWER: "~2.7%", englishWERValue: 2.7,
            multiWER: "—", speedLabel: "~2× faster", speedFactor: 2,
            lang: "English only", englishOnly: true,
            blurb: "English-only medium — slightly sharper English than the multilingual medium.",
            recommendation: "High-accuracy English dictation on a capable Mac."
        ),
        WhisperModelOption(
            id: "large-v3", display: "large-v3", size: "~3.1 GB",
            quality: "Best", folderName: "openai_whisper-large-v3",
            params: "1.55B", ram: "~3.9 GB",
            englishWER: "~2.4%", englishWERValue: 2.4,
            multiWER: "~3.5%", speedLabel: "real-time", speedFactor: 1,
            lang: "Multilingual", englishOnly: false,
            blurb: "The most accurate Whisper model; best for multilingual and hard audio.",
            recommendation: "Best accuracy — needs 16 GB+ RAM and the most patience."
        ),
        WhisperModelOption(
            id: "large-v3_947MB", display: "large-v3 (947MB)", size: "~947 MB",
            quality: "Best", folderName: "openai_whisper-large-v3_947MB",
            params: "1.55B (quantized)", ram: "~1.6 GB",
            englishWER: "~2.6%", englishWERValue: 2.6,
            multiWER: "~3.8%", speedLabel: "~1.2× faster", speedFactor: 1.2,
            lang: "Multilingual", englishOnly: false,
            blurb: "Quantized large-v3 — much smaller and lighter while keeping most of the accuracy.",
            recommendation: "Large-v3 accuracy on 8–16 GB Macs."
        ),
        WhisperModelOption(
            id: "large-v3-v20240930", display: "large-v3 (2024-09)", size: "~3.1 GB",
            quality: "Best", folderName: "openai_whisper-large-v3-v20240930",
            params: "1.55B", ram: "~3.9 GB",
            englishWER: "~2.4%", englishWERValue: 2.4,
            multiWER: "~3.5%", speedLabel: "real-time", speedFactor: 1,
            lang: "Multilingual", englishOnly: false,
            blurb: "large-v3 training refresh (2024-09). Same architecture, minor improvements.",
            recommendation: "Use plain large-v3 unless you specifically need this revision."
        ),
        WhisperModelOption(
            id: "large-v2", display: "large-v2", size: "~3.1 GB",
            quality: "Best", folderName: "openai_whisper-large-v2",
            params: "1.55B", ram: "~3.9 GB",
            englishWER: "~2.7%", englishWERValue: 2.7,
            multiWER: "~4%", speedLabel: "real-time", speedFactor: 1,
            lang: "Multilingual", englishOnly: false,
            blurb: "Previous large generation. Slightly behind large-v3; keep only if you already use it.",
            recommendation: "Legacy — prefer large-v3 for new downloads."
        ),
        WhisperModelOption(
            id: "distil-large-v3", display: "distil-large-v3", size: "~750 MB",
            quality: "Accurate", folderName: "distil-whisper_distil-large-v3",
            params: "809M", ram: "~2.3 GB",
            englishWER: "~3.0%", englishWERValue: 3.0,
            multiWER: "~4.5%", speedLabel: "~8× faster", speedFactor: 8,
            lang: "Multilingual", englishOnly: false,
            blurb: "Distilled large — about 8× faster than large-v3 at a small accuracy cost.",
            recommendation: "Near-large speed, much faster — a great middle ground."
        ),
    ]

    /// Find an option by bare id (or by full folderName, for backward compat).
    static func find(id: String) -> WhisperModelOption {
        if let m = all.first(where: { $0.id == id || $0.folderName == id }) { return m }
        return WhisperModelOption(
            id: id, display: id, size: "?", quality: "custom", folderName: id,
            params: "?", ram: "?", englishWER: "?", englishWERValue: 9,
            multiWER: "?", speedLabel: "?", speedFactor: 1, lang: "?",
            englishOnly: false, blurb: "Custom model.", recommendation: ""
        )
    }

    /// The bare id WhisperKit wants (strips any openai_/distil-whisper_ prefix).
    static func bareId(_ anyId: String) -> String {
        if let m = all.first(where: { $0.folderName == anyId }) { return m.id }
        return anyId
            .replacingOccurrences(of: "openai_whisper-", with: "whisper-")
            .replacingOccurrences(of: "distil-whisper_", with: "distil-")
    }

    // MARK: - Derived helpers for the UI bars

    /// Accuracy as a 0…1 fraction (1 = best WER, 0 = worst in this list).
    var accuracyFraction: Double {
        let best = 2.4, worst = 9.0
        let v = min(max(englishWERValue, best), worst)
        return 1 - (v - best) / (worst - best)
    }

    /// Speed as a 0…1 fraction (1 = ~10× faster, 0 = real-time).
    var speedFraction: Double {
        min(max(speedFactor, 1), 10) / 10
    }

    /// Punchy one-line decision tag (ChatGPT rec: lead with the verdict, not WER).
    var decision: String {
        switch quality {
        case "Fast":    return englishOnly ? "Fastest · English" : "Fastest"
        case "Balanced":return "Best balance ⭐"
        case "Accurate":return "High accuracy"
        case "Best":    return "Highest accuracy"
        default:        return quality
        }
    }

    /// Human estimate of processing time per minute of audio (ChatGPT rec).
    /// Derived from the real-time factor: at 1× a minute takes ~60s; at 10×
    /// it takes ~6s. Rounded to a friendly "~N sec".
    var secPerMin: String {
        let secs = 60.0 / max(speedFactor, 0.5)
        let rounded = secs < 10 ? Int(secs.rounded()) : Int((secs / 5).rounded() * 5)
        return "~\(max(rounded, 1)) sec / min audio"
    }
}
