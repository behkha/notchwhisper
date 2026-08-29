import Foundation

/// A Whisper model that can be downloaded from Hugging Face (argmaxinc/whisperkit-coreml).
///
/// IMPORTANT: WhisperKit's `download(variant:)` searches the repo with the glob
/// `"*<variant>/*"`. That pattern is only UNIQUE when `variant` is the folder
/// name minus its publisher prefix (`openai_whisper-` / `distil-whisper_`):
///   openai_whisper-large-v3_turbo        → variant "whisper-large-v3_turbo"
///   distil-whisper_distil-large-v3       → variant "distil-large-v3"
/// (The glob requires the match to END right before the "/", so suffixed
/// siblings like `..._954MB` can never collide — verified against the glob
/// matcher in WhisperKit.)
///
/// The FULL catalog below mirrors every folder published in
/// argmaxinc/whisperkit-coreml (27 variants incl. turbo + quantized builds).
/// WER/speed figures are approximate (Whisper paper + HF model cards +
/// common Apple Silicon benchmarks); real-world accuracy varies by audio,
/// accent and language.
struct WhisperModelOption: Identifiable, Hashable {
    let id: String          // bare variant for WhisperKit.download, e.g. "whisper-base"
    let display: String     // human label, e.g. "base"
    let size: String        // approximate download size
    let quality: String     // short tag: Fast / Balanced / Accurate / Best
    let folderName: String  // full HF folder name, e.g. "openai_whisper-base"

    // MARK: - Decision helper data
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

    /// Derive the bare variant WhisperKit wants from a full HF folder name.
    static func bareId(fromFolder folder: String) -> String {
        if folder.hasPrefix("openai_whisper-") {
            return "whisper-" + folder.dropFirst("openai_whisper-".count)
        }
        if folder.hasPrefix("distil-whisper_") {
            return String(folder.dropFirst("distil-whisper_".count))
        }
        return folder
    }

    /// Compact catalog builder — keeps the 27-entry list readable.
    private static func m(
        _ folder: String, _ display: String, _ size: String, _ quality: String,
        params: String, ram: String, wer: Double, multi: Double?, speed: Double,
        blurb: String, rec: String
    ) -> WhisperModelOption {
        let englishOnly = folder.contains(".en")
        return WhisperModelOption(
            id: bareId(fromFolder: folder),
            display: display,
            size: size,
            quality: quality,
            folderName: folder,
            params: params,
            ram: ram,
            englishWER: String(format: "~%.1f%%", wer),
            englishWERValue: wer,
            multiWER: englishOnly ? "—" : (multi.map { String(format: "~%.1f%%", $0) } ?? "—"),
            speedLabel: speed >= 9.5 ? "~10× faster" : (speed <= 1.05 ? "real-time" : String(format: "~%.0f× faster", speed)),
            speedFactor: speed,
            lang: englishOnly ? "English only" : "Multilingual",
            englishOnly: englishOnly,
            blurb: blurb,
            recommendation: rec
        )
    }

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

    /// Every model published in argmaxinc/whisperkit-coreml (as of 2026-08),
    /// ordered tiny → base → small → medium → large-v2 → large-v3 → distil.
    static let all: [WhisperModelOption] = [
        // MARK: tiny family
        m("openai_whisper-tiny", "tiny", "~75 MB", "Fast",
          params: "39M", ram: "~270 MB", wer: 7.6, multi: 12, speed: 10,
          blurb: "Smallest model — near-instant, but noticeably less accurate.",
          rec: "Pick only when speed is everything and rough text is fine."),
        m("openai_whisper-tiny.en", "tiny.en", "~75 MB", "Fast",
          params: "39M", ram: "~270 MB", wer: 7.0, multi: nil, speed: 10,
          blurb: "English-only tiny. A touch better English than the multilingual tiny.",
          rec: "Quick English notes where accuracy isn't critical."),

        // MARK: base family
        m("openai_whisper-base", "base", "~140 MB", "Balanced",
          params: "74M", ram: "~390 MB", wer: 5.0, multi: 10, speed: 7,
          blurb: "A solid balance of speed and accuracy for everyday multilingual dictation.",
          rec: "Good default for most people — fast and accurate enough."),
        m("openai_whisper-base.en", "base.en", "~140 MB", "Balanced",
          params: "74M", ram: "~390 MB", wer: 4.5, multi: nil, speed: 7,
          blurb: "English-only base. Better English than the multilingual base.",
          rec: "English-only everyday dictation, a bit sharper than base."),

        // MARK: small family
        m("openai_whisper-small", "small", "~470 MB", "Balanced",
          params: "244M", ram: "~850 MB", wer: 3.4, multi: 7, speed: 4,
          blurb: "Where Whisper starts to feel genuinely accurate; handles accents and noise well.",
          rec: "Best all-rounder on 16 GB+ Macs — accuracy without the wait."),
        m("openai_whisper-small.en", "small.en", "~470 MB", "Balanced",
          params: "244M", ram: "~850 MB", wer: 3.0, multi: nil, speed: 4,
          blurb: "English-only small — excellent English accuracy at a friendly size.",
          rec: "Best English-only balance on most laptops."),
        m("openai_whisper-small_216MB", "small (216MB)", "~216 MB", "Balanced",
          params: "244M (quantized)", ram: "~550 MB", wer: 3.6, multi: 7.5, speed: 4.5,
          blurb: "Quantized multilingual small — smaller download and RAM, near the same accuracy.",
          rec: "Space-saving multilingual pick for 8 GB Macs."),
        m("openai_whisper-small.en_217MB", "small.en (217MB)", "~217 MB", "Balanced",
          params: "244M (quantized)", ram: "~550 MB", wer: 3.2, multi: nil, speed: 4.5,
          blurb: "Quantized English small — smaller download and lower RAM, nearly the same accuracy.",
          rec: "Space-saving English pick for 8 GB Macs."),

        // MARK: medium family
        m("openai_whisper-medium", "medium", "~1.5 GB", "Accurate",
          params: "769M", ram: "~2.1 GB", wer: 2.9, multi: 5, speed: 2,
          blurb: "High accuracy with strong multilingual support; comfortable on 16 GB+ Macs.",
          rec: "High accuracy that still finishes in roughly real time."),
        m("openai_whisper-medium.en", "medium.en", "~1.5 GB", "Accurate",
          params: "769M", ram: "~2.1 GB", wer: 2.7, multi: nil, speed: 2,
          blurb: "English-only medium — slightly sharper English than the multilingual medium.",
          rec: "High-accuracy English dictation on a capable Mac."),

        // MARK: large-v2 family
        m("openai_whisper-large-v2", "large-v2", "~3.1 GB", "Best",
          params: "1.55B", ram: "~3.9 GB", wer: 2.7, multi: 4, speed: 1,
          blurb: "Previous large generation. Slightly behind large-v3; keep only if you already use it.",
          rec: "Legacy — prefer large-v3 for new downloads."),
        m("openai_whisper-large-v2_949MB", "large-v2 (949MB)", "~949 MB", "Best",
          params: "1.55B (quantized)", ram: "~1.6 GB", wer: 2.9, multi: 4.3, speed: 1.2,
          blurb: "Quantized large-v2 — much smaller while keeping most of the accuracy.",
          rec: "Large-v2 accuracy on 8–16 GB Macs."),
        m("openai_whisper-large-v2_turbo", "large-v2 turbo", "~1.6 GB", "Best",
          params: "809M", ram: "~2.3 GB", wer: 2.9, multi: 4.2, speed: 8,
          blurb: "Turbo decoder distilled from large-v2 — near-large accuracy at 8× the speed.",
          rec: "Fast + accurate multilingual pick for 16 GB Macs."),
        m("openai_whisper-large-v2_turbo_955MB", "large-v2 turbo (955MB)", "~955 MB", "Best",
          params: "809M (quantized)", ram: "~1.6 GB", wer: 3.0, multi: 4.4, speed: 8,
          blurb: "Quantized large-v2 turbo — turbo speed at half the download size.",
          rec: "Turbo speed when disk space is tight."),

        // MARK: large-v3 family
        m("openai_whisper-large-v3", "large-v3", "~3.1 GB", "Best",
          params: "1.55B", ram: "~3.9 GB", wer: 2.4, multi: 3.5, speed: 1,
          blurb: "The most accurate Whisper model; best for multilingual and hard audio.",
          rec: "Best accuracy — needs 16 GB+ RAM and the most patience."),
        m("openai_whisper-large-v3_947MB", "large-v3 (947MB)", "~947 MB", "Best",
          params: "1.55B (quantized)", ram: "~1.6 GB", wer: 2.6, multi: 3.8, speed: 1.2,
          blurb: "Quantized large-v3 — much smaller and lighter while keeping most of the accuracy.",
          rec: "Large-v3 accuracy on 8–16 GB Macs."),
        m("openai_whisper-large-v3_turbo", "large-v3 turbo", "~1.6 GB", "Best",
          params: "809M", ram: "~2.3 GB", wer: 2.6, multi: 3.9, speed: 8,
          blurb: "The sweet spot: near-large-v3 accuracy at 8× the speed. Great for live dictation.",
          rec: "Best all-round upgrade — recommended for live dictation on 16 GB Macs."),
        m("openai_whisper-large-v3_turbo_954MB", "large-v3 turbo (954MB)", "~954 MB", "Best",
          params: "809M (quantized)", ram: "~1.6 GB", wer: 2.7, multi: 4.1, speed: 8,
          blurb: "Quantized large-v3 turbo — turbo speed at half the download size.",
          rec: "Turbo speed when disk space is tight."),

        // MARK: large-v3 2024-09 refresh family
        m("openai_whisper-large-v3-v20240930", "large-v3 (2024-09)", "~3.1 GB", "Best",
          params: "1.55B", ram: "~3.9 GB", wer: 2.4, multi: 3.5, speed: 1,
          blurb: "large-v3 training refresh (2024-09). Same architecture, minor improvements.",
          rec: "Use plain large-v3 unless you specifically need this revision."),
        m("openai_whisper-large-v3-v20240930_547MB", "large-v3 (2024-09, 547MB)", "~547 MB", "Accurate",
          params: "1.55B (quantized)", ram: "~1.1 GB", wer: 2.8, multi: 4.0, speed: 1.5,
          blurb: "Compact quantized build of the 2024-09 refresh — smallest large-class download.",
          rec: "Large-class accuracy under 600 MB."),
        m("openai_whisper-large-v3-v20240930_626MB", "large-v3 (2024-09, 626MB)", "~626 MB", "Accurate",
          params: "1.55B (quantized)", ram: "~1.2 GB", wer: 2.7, multi: 3.9, speed: 1.5,
          blurb: "Slightly larger quantized 2024-09 build — a bit sharper than the 547 MB one.",
          rec: "Large-class accuracy under 700 MB."),
        m("openai_whisper-large-v3-v20240930_turbo", "large-v3 turbo (2024-09)", "~1.6 GB", "Best",
          params: "809M", ram: "~2.3 GB", wer: 2.6, multi: 3.9, speed: 8,
          blurb: "Turbo build of the 2024-09 refresh — same speed, marginal accuracy gains.",
          rec: "Alternative to plain large-v3 turbo."),
        m("openai_whisper-large-v3-v20240930_turbo_632MB", "large-v3 turbo (2024-09, 632MB)", "~632 MB", "Best",
          params: "809M (quantized)", ram: "~1.3 GB", wer: 2.7, multi: 4.1, speed: 8,
          blurb: "Quantized turbo of the 2024-09 refresh — smallest turbo download.",
          rec: "Turbo speed under 700 MB."),

        // MARK: distil family
        m("distil-whisper_distil-large-v3", "distil-large-v3", "~750 MB", "Accurate",
          params: "809M", ram: "~2.3 GB", wer: 3.0, multi: 4.5, speed: 8,
          blurb: "Distilled large — about 8× faster than large-v3 at a small accuracy cost.",
          rec: "Near-large accuracy, much faster — a great middle ground."),
        m("distil-whisper_distil-large-v3_594MB", "distil-large-v3 (594MB)", "~594 MB", "Accurate",
          params: "809M (quantized)", ram: "~1.6 GB", wer: 3.2, multi: 4.7, speed: 8,
          blurb: "Quantized distil-large-v3 — distil speed at a smaller download.",
          rec: "Fast + accurate when disk space is tight."),
        m("distil-whisper_distil-large-v3_turbo", "distil-large-v3 turbo", "~750 MB", "Accurate",
          params: "809M", ram: "~2.3 GB", wer: 3.0, multi: 4.5, speed: 8,
          blurb: "Turbo variant of distil-large-v3 — same class of speed and accuracy.",
          rec: "Alternative to plain distil-large-v3."),
        m("distil-whisper_distil-large-v3_turbo_600MB", "distil-large-v3 turbo (600MB)", "~600 MB", "Accurate",
          params: "809M (quantized)", ram: "~1.6 GB", wer: 3.2, multi: 4.7, speed: 8,
          blurb: "Quantized distil turbo — distil speed, half the size.",
          rec: "Fast + accurate under 700 MB."),
    ]

    /// Custom (Hugging Face search) model ids use "<repoId>:<folder>".
    static func parseCustom(_ modelId: String) -> (repo: String, folder: String)? {
        guard modelId.contains(":"), !modelId.hasPrefix("whisper-"), !modelId.hasPrefix("distil-") else { return nil }
        let parts = modelId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Find an option by bare id (or by full folderName, for backward compat).
    /// Custom "<repoId>:<folder>" ids (Hugging Face search downloads) get a
    /// friendly display without a catalog entry.
    static func find(id: String) -> WhisperModelOption {
        if let m = all.first(where: { $0.id == id || $0.folderName == id }) { return m }
        if let custom = parseCustom(id) {
            let display = custom.folder
                .replacingOccurrences(of: "openai_whisper-", with: "")
                .replacingOccurrences(of: "distil-whisper_", with: "")
            return WhisperModelOption(
                id: id, display: "\(display) · \(custom.repo)", size: "?", quality: "custom",
                folderName: custom.folder,
                params: "?", ram: "?", englishWER: "?", englishWERValue: 9,
                multiWER: "?", speedLabel: "?", speedFactor: 1, lang: "?",
                englishOnly: false, blurb: "Custom model from Hugging Face repo \(custom.repo).",
                recommendation: ""
            )
        }
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
        if anyId.hasPrefix("openai_whisper-") { return "whisper-" + anyId.dropFirst("openai_whisper-".count) }
        if anyId.hasPrefix("distil-whisper_") { return String(anyId.dropFirst("distil-whisper_".count)) }
        return anyId
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

    /// Punchy one-line decision tag.
    var decision: String {
        switch quality {
        case "Fast":    return englishOnly ? "Fastest · English" : "Fastest"
        case "Balanced":return "Best balance ⭐"
        case "Accurate":return "High accuracy"
        case "Best":    return "Highest accuracy"
        default:        return quality
        }
    }

    /// Human estimate of processing time per minute of audio.
    /// Derived from the real-time factor: at 1× a minute takes ~60s; at 10×
    /// it takes ~6s. Rounded to a friendly "~N sec".
    var secPerMin: String {
        let secs = 60.0 / max(speedFactor, 0.5)
        let rounded = secs < 10 ? Int(secs.rounded()) : Int((secs / 5).rounded() * 5)
        return "~\(max(rounded, 1)) sec / min audio"
    }
}
