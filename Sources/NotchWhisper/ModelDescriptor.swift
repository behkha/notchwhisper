import Foundation

// MARK: - Runtime registry
//
// A model being loadable by `transformers` says nothing about whether THIS app
// can run it. The registry below is the authority: discovery filters and badges
// against it, and a format that isn't listed is reported as unsupported with a
// reason rather than silently hidden.

/// An inference backend this app actually ships.
enum ModelEngine: String, Codable, Hashable, CaseIterable {
    /// Core ML Whisper through WhisperKit.
    case whisperKit
    /// GGUF Qwen3-ASR through the vendored llama.cpp + mtmd.
    case llamaCPP

    var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit"
        case .llamaCPP:   return "llama.cpp"
        }
    }

    var detailName: String {
        switch self {
        case .whisperKit: return "WhisperKit · Core ML"
        case .llamaCPP:   return "llama.cpp · Metal"
        }
    }
}

/// Weight container formats. Only the ones a `SupportedRuntime` lists can be
/// installed; the rest exist so unsupported models can be explained (§69).
enum ModelFileFormat: String, Codable, Hashable, CaseIterable, Identifiable {
    case coreML, gguf, safetensors, onnx, other
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coreML:      return "Core ML"
        case .gguf:        return "GGUF"
        case .safetensors: return "Safetensors"
        case .onnx:        return "ONNX"
        case .other:       return "Other"
        }
    }
}

/// What the app knows about one shipped inference backend.
struct SupportedRuntime: Identifiable {
    let engine: ModelEngine
    var id: String { engine.rawValue }
    /// Weight formats this backend can load.
    let formats: [ModelFileFormat]
    /// Hardware acceleration paths, in the order the backend prefers them.
    let accelerators: [String]
    let minimumOS: String
    let requiresAppleSilicon: Bool
    /// Can drive live (streaming) dictation, not just hold-to-talk.
    let supportsStreaming: Bool
    /// Whether loading a model from this backend executes code shipped in the
    /// repository. Both backends load compiled weights only — no repo code is
    /// ever executed, and no pickle-based formats are accepted (§80).
    let executesRepositoryCode: Bool
    let loaderDescription: String
}

enum ModelRuntimeRegistry {
    static let all: [SupportedRuntime] = [
        SupportedRuntime(
            engine: .whisperKit,
            formats: [.coreML],
            accelerators: ["Neural Engine", "GPU", "CPU"],
            minimumOS: "macOS 14",
            requiresAppleSilicon: false,
            supportsStreaming: true,
            executesRepositoryCode: false,
            loaderDescription: "Loads compiled .mlmodelc bundles. No repository code is executed."
        ),
        SupportedRuntime(
            engine: .llamaCPP,
            formats: [.gguf],
            accelerators: ["Metal GPU", "CPU"],
            minimumOS: "macOS 14",
            requiresAppleSilicon: true,
            supportsStreaming: false,
            executesRepositoryCode: false,
            loaderDescription: "Loads GGUF tensors through the bundled llama.cpp. No repository code is executed."
        ),
    ]

    static func runtime(for engine: ModelEngine) -> SupportedRuntime {
        all.first { $0.engine == engine } ?? all[0]
    }

    /// Every format the app can install today.
    static var supportedFormats: [ModelFileFormat] {
        Array(Set(all.flatMap(\.formats))).sorted { $0.rawValue < $1.rawValue }
    }

    static func supports(_ format: ModelFileFormat) -> Bool {
        supportedFormats.contains(format)
    }

    /// Plain-language reason a format can't be installed (§69).
    static func unsupportedReason(for format: ModelFileFormat) -> String {
        switch format {
        case .safetensors:
            return "This repository ships PyTorch/Safetensors weights. NotchWhisper runs Core ML and GGUF models only."
        case .onnx:
            return "This repository ships ONNX weights. NotchWhisper has no ONNX runtime."
        case .other:
            return "NotchWhisper couldn't identify a weight format it can load in this repository."
        case .coreML, .gguf:
            return ""
        }
    }
}

// MARK: - Trust

/// Who published a model, and whether this app has actually run it.
///
/// These are three separate facts and the UI keeps them separate: "Official"
/// describes the publisher, "Verified" describes NotchWhisper's own testing,
/// and compatibility is evaluated per-Mac. None of them implies the others.
enum ModelTrust: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Tested by NotchWhisper against this runtime.
    case verified
    /// Published by a recognized upstream organization, untested here.
    case official
    /// Published by a community developer.
    case community
    /// Imported by the user from disk.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .verified:  return "Verified"
        case .official:  return "Official"
        case .community: return "Community"
        case .custom:    return "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .verified:  return "checkmark.seal.fill"
        case .official:  return "building.2.fill"
        case .community: return "person.2.fill"
        case .custom:    return "folder.fill"
        }
    }

    var explanation: String {
        switch self {
        case .verified:
            return "NotchWhisper has tested this model with this runtime."
        case .official:
            return "Published by the upstream organization. NotchWhisper hasn't tested this build."
        case .community:
            return "Published by a community developer. NotchWhisper hasn't tested this build."
        case .custom:
            return "You imported this model from your own disk."
        }
    }
}

// MARK: - Metrics with provenance
//
// §13: never invent an accuracy or speed number. Every rating carries where it
// came from, and "unknown" renders as "Not benchmarked" rather than a guess.

enum MetricProvenance: String, Codable, Hashable {
    /// Measured by this app, on this Mac.
    case measured
    /// From the model card / published paper. Approximate.
    case published
    /// Derived from published figures for a related build.
    case estimated
    case unknown

    var note: String? {
        switch self {
        case .measured:  return "Measured on this Mac"
        case .published: return "Published figure — approximate"
        case .estimated: return "Estimated from the base model"
        case .unknown:   return nil
        }
    }
}

/// One interpretable dimension (§54) — never an opaque composite score.
struct RatedMetric: Hashable {
    /// Human label, e.g. "Excellent", "~2.6% WER", "~8× real time".
    let display: String
    /// 0…1 for the meter, nil when unknown.
    let fraction: Double?
    let provenance: MetricProvenance

    static let unknown = RatedMetric(display: "Not benchmarked", fraction: nil, provenance: .unknown)

    var isKnown: Bool { provenance != .unknown }
}

// MARK: - Capabilities
//
// §67: speech models are not interchangeable. What a model can do is recorded
// explicitly, and the UI never implies a capability the runtime doesn't provide.

struct ModelCapabilities: Hashable {
    /// BCP-47 / ISO-639-1 codes. Empty = unknown, not "none".
    let languages: [String]
    /// Where the language list came from, for the detail view.
    let languageSource: String?
    let speechToText: Bool
    let translation: Bool
    let timestamps: Bool
    let wordTimestamps: Bool
    /// Can stream partial results — this is what live dictation needs.
    let streaming: Bool
    let diarization: Bool

    var isMultilingual: Bool { languages.count > 1 }

    var languageCountLabel: String {
        if languages.isEmpty { return "Unknown" }
        if languages.count == 1 {
            return Self.languageName(languages[0]) + " only"
        }
        return "\(languages.count) languages"
    }

    func supports(languageCode: String) -> Bool {
        languages.contains(languageCode.lowercased())
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// A few well-known languages first, then the rest alphabetically — what
    /// the detail view shows before "and N more".
    var prominentLanguages: [String] {
        let priority = ["en", "es", "fr", "de", "zh", "ja", "ko", "ar", "pt", "ru", "nl", "it", "tr", "fa", "hi"]
        let present = priority.filter { languages.contains($0) }
        let rest = languages.filter { !priority.contains($0) }.sorted()
        return present + rest
    }
}

/// Language sets used by the built-in catalogs.
enum ModelLanguageSets {
    /// The 99 languages the multilingual Whisper checkpoints are trained on,
    /// plus Cantonese (`yue`), which large-v3 adds — hence the two sets below.
    /// Both come from the OpenAI Whisper model card, not from a guess.
    private static let whisperAll100: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv",
        "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr",
        "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu",
        "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]

    /// large-v2 and earlier: 99 languages.
    static let whisperMultilingual: [String] = whisperAll100.filter { $0 != "yue" }

    /// large-v3 and its derivatives: the same 99 plus Cantonese.
    static let whisperMultilingualV3: [String] = whisperAll100

    static let englishOnly = ["en"]

    /// Qwen3-ASR's supported languages (Qwen3-ASR model card).
    static let qwen3ASR = ["zh", "en", "ja", "ko", "es", "fr", "de", "ar", "it", "pt", "ru"]

    /// Languages offered in the discovery filter, derived from what the
    /// installed + catalog models actually declare (never hardcoded in a view).
    static func filterLanguages(from descriptors: [ModelDescriptor]) -> [String] {
        var counts: [String: Int] = [:]
        for d in descriptors {
            for code in d.capabilities.languages { counts[code, default: 0] += 1 }
        }
        // Keep languages at least one model supports, most-supported first, then
        // alphabetical by localized name for a stable menu.
        return counts.keys.sorted {
            ModelCapabilities.languageName($0) < ModelCapabilities.languageName($1)
        }
    }
}

// MARK: - Resources

struct ModelResources: Hashable {
    /// e.g. "1.55B". nil when the repo doesn't declare it.
    let parameterCount: String?
    /// Download size in bytes. 0 = unknown.
    let diskBytes: Int64
    /// Estimated resident footprint in bytes. 0 = unknown.
    let memoryBytes: Int64
    /// e.g. "Q8_0", "INT8", nil for full precision / unknown.
    let quantization: String?

    var diskLabel: String {
        diskBytes > 0 ? ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file) : "—"
    }
    var memoryLabel: String {
        memoryBytes > 0 ? "~" + ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .file) : "—"
    }
}

// MARK: - Descriptor

/// The app's own normalized view of a model — the ONLY model type the UI reads.
///
/// Remote Hugging Face metadata and local installation state are deliberately
/// separate concerns: a descriptor says what a model *is*, `ModelInstallation`
/// says what happened to it on this Mac.
struct ModelDescriptor: Identifiable, Hashable {
    /// Matches `Settings.modelId` — the app-wide model identity.
    let id: String

    // Identity
    let displayName: String
    let provider: String
    /// Hugging Face handle, for the org avatar.
    let providerHandle: String
    let repositoryId: String
    let repositoryURL: URL
    /// Pinned revision, nil = track the repository's default branch.
    let revision: String?
    /// Core ML folder name inside the repo (Whisper models only).
    let folderName: String?

    // Runtime
    let engine: ModelEngine
    let format: ModelFileFormat

    // Trust
    let trust: ModelTrust
    let license: String?
    /// e.g. "Core ML build by Argmax" — who repackaged the upstream weights.
    let packagerNote: String?

    // Substance
    let capabilities: ModelCapabilities
    let resources: ModelResources
    let accuracy: RatedMetric
    let speed: RatedMetric
    let blurb: String
    let recommendation: String

    /// Part of the shipped catalog (as opposed to discovered or imported).
    let isBuiltIn: Bool

    var runtime: SupportedRuntime { ModelRuntimeRegistry.runtime(for: engine) }

    /// Every model in this app runs on the user's Mac. That is a property of
    /// how the app executes it, not of the model's license (§42).
    var runsOnDevice: Bool { true }

    var modelCardURL: URL { repositoryURL }

    /// Short capability tags for the row/card (§43 — one small vocabulary).
    var tags: [String] {
        var out: [String] = []
        if capabilities.isMultilingual { out.append("Multilingual") }
        if resources.memoryBytes > 0, resources.memoryBytes <= 1_200_000_000 { out.append("Lightweight") }
        if let f = speed.fraction, f >= 0.7 { out.append("Low latency") }
        if let f = accuracy.fraction, f >= 0.85 { out.append("High accuracy") }
        if resources.quantization != nil { out.append("Quantized") }
        if capabilities.streaming { out.append("Live dictation") }
        if runtime.requiresAppleSilicon { out.append("Apple Silicon") }
        return out
    }
}

// MARK: - Compatibility evaluation
//
// §9: check before downloading, warn rather than block, and never claim a hard
// incompatibility that isn't one.

struct ModelCompatibility {
    enum Verdict: Int, Comparable {
        case recommended, supported, tight, needsMoreMemory, unsupported
        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            // Deliberately not "Recommended for this Mac": that phrase is a
            // recommendation *award*, which exactly one model earns. This is a
            // per-model compatibility verdict and many models can share it.
            case .recommended:     return "Runs great here"
            case .supported:       return "Runs well"
            case .tight:           return "Tight fit"
            case .needsMoreMemory: return "Requires more memory"
            case .unsupported:     return "Not supported"
            }
        }

        var symbol: String {
            switch self {
            case .recommended:     return "checkmark.seal.fill"
            case .supported:       return "checkmark.circle.fill"
            case .tight:           return "exclamationmark.triangle.fill"
            case .needsMoreMemory: return "memorychip"
            case .unsupported:     return "xmark.octagon.fill"
            }
        }

        /// A genuine technical incompatibility — the only case that blocks.
        var isBlocking: Bool { self == .unsupported }
    }

    struct Check: Identifiable {
        let id = UUID()
        let passed: Bool
        let text: String
    }

    let verdict: Verdict
    let summary: String
    let checks: [Check]
    let requiredDiskBytes: Int64
    let freeDiskBytes: Int64

    var hasEnoughDisk: Bool {
        requiredDiskBytes <= 0 || freeDiskBytes <= 0 || freeDiskBytes >= requiredDiskBytes + 500_000_000
    }

    /// Disk is critically short — the download can't finish at all.
    var diskIsCritical: Bool {
        requiredDiskBytes > 0 && freeDiskBytes > 0 && freeDiskBytes < requiredDiskBytes
    }

    /// Just the verdict, without building the check list or the prose.
    ///
    /// Row and card rendering asks "is this model usable?" for every visible
    /// model on every frame; the full evaluation allocates a dozen strings each
    /// time, which the list can't afford.
    static func verdict(for model: ModelDescriptor, hw: HardwareInfo = .current) -> Verdict {
        let runtime = model.runtime
        if runtime.requiresAppleSilicon, !hw.isAppleSilicon { return .unsupported }
        if !ModelRuntimeRegistry.supports(model.format) { return .unsupported }
        let need = model.resources.memoryBytes
        guard need > 0 else { return .supported }
        let ratio = Double(need) / (Double(hw.physicalMemory) * 0.55)
        var verdict: Verdict
        switch ratio {
        case ..<0.45: verdict = .recommended
        case ..<0.75: verdict = .supported
        case ..<1.05: verdict = .tight
        default:      verdict = .needsMoreMemory
        }
        if !hw.isAppleSilicon, let f = model.speed.fraction, f < 0.25, verdict < .tight {
            verdict = .tight
        }
        return verdict
    }

    static func evaluate(_ model: ModelDescriptor,
                         hw: HardwareInfo = .current,
                         freeDisk: Int64 = HardwareInfo.freeDiskBytes()) -> ModelCompatibility {
        var checks: [Check] = []
        let runtime = model.runtime

        // 1. Architecture.
        let archOK = !runtime.requiresAppleSilicon || hw.isAppleSilicon
        checks.append(Check(
            passed: archOK,
            text: archOK
                ? (hw.isAppleSilicon ? "Apple Silicon supported" : "Runs on Intel")
                : "Needs an Apple Silicon Mac"
        ))

        // 2. Format / runtime support.
        let formatOK = ModelRuntimeRegistry.supports(model.format)
        checks.append(Check(
            passed: formatOK,
            text: formatOK
                ? "\(model.format.displayName) is supported by the \(runtime.engine.displayName) runtime"
                : ModelRuntimeRegistry.unsupportedReason(for: model.format)
        ))

        // 3. Memory. Budget ~55% of physical RAM: what a background utility can
        //    claim without paging the user's foreground app.
        let need = model.resources.memoryBytes
        let budget = Double(hw.physicalMemory) * 0.55
        let ratio = need > 0 ? Double(need) / budget : 0
        let memoryOK = need == 0 || ratio < 1.05
        let recommendedGB = need > 0 ? max(8, Int((Double(need) / 1_073_741_824 / 0.55).rounded(.up))) : 0
        checks.append(Check(
            passed: memoryOK,
            text: need == 0
                ? "Memory use unknown"
                : (memoryOK
                    ? "\(recommendedGB) GB RAM recommended · you have \(memGB(hw))"
                    : "Needs roughly \(recommendedGB) GB RAM · you have \(memGB(hw))")
        ))

        // 4. Acceleration.
        let accel = hw.isAppleSilicon
            ? (model.engine == .llamaCPP ? "Metal acceleration available" : "Neural Engine available")
            : "CPU only — no Neural Engine on this Mac"
        checks.append(Check(passed: hw.isAppleSilicon, text: accel))

        // 5. Disk.
        let needDisk = model.resources.diskBytes
        let diskOK = needDisk <= 0 || freeDisk <= 0 || freeDisk >= needDisk + 500_000_000
        checks.append(Check(
            passed: diskOK,
            text: needDisk <= 0
                ? "Download size unknown"
                : "\(ByteCountFormatter.string(fromByteCount: max(0, freeDisk), countStyle: .file)) free disk space"
        ))

        // Verdict.
        var verdict: Verdict
        if !archOK || !formatOK {
            verdict = .unsupported
        } else if need == 0 {
            verdict = .supported
        } else {
            switch ratio {
            case ..<0.45: verdict = .recommended
            case ..<0.75: verdict = .supported
            case ..<1.05: verdict = .tight
            default:      verdict = .needsMoreMemory
            }
            // Intel has no Neural Engine: the slow tiers are impractical there.
            if !hw.isAppleSilicon, let f = model.speed.fraction, f < 0.25,
               verdict < .tight {
                verdict = .tight
            }
        }

        let summary: String
        switch verdict {
        case .recommended:
            summary = "Comfortably within your \(memGB(hw)) of memory, with room for everything else you're running."
        case .supported:
            summary = "Runs well on your \(memGB(hw)) of memory."
        case .tight:
            summary = hw.isAppleSilicon
                ? "Uses a large share of your \(memGB(hw)) of memory — expect pressure with other apps open."
                : "Heavy for an Intel Mac without a Neural Engine — transcription will be slow."
        case .needsMoreMemory:
            summary = "Needs about \(recommendedGB) GB of memory; this Mac has \(memGB(hw)). A smaller or quantized build will feel much better."
        case .unsupported:
            summary = !archOK
                ? "\(runtime.engine.displayName) needs an Apple Silicon Mac."
                : ModelRuntimeRegistry.unsupportedReason(for: model.format)
        }

        return ModelCompatibility(
            verdict: verdict, summary: summary, checks: checks,
            requiredDiskBytes: needDisk, freeDiskBytes: freeDisk
        )
    }

    private static func memGB(_ hw: HardwareInfo) -> String {
        hw.memoryGB >= 1
            ? String(format: "%.0f GB", hw.memoryGB.rounded())
            : String(format: "%.1f GB", hw.memoryGB)
    }
}

// MARK: - Catalog service
//
// Builds descriptors from the shipped catalogs. Metadata-driven: adding a model
// means adding catalog data, never touching a view.

@MainActor
enum ModelCatalogService {

    /// Every model the app ships knowledge of, Whisper + Qwen3-ASR.
    static var builtIn: [ModelDescriptor] {
        WhisperModelOption.all.map(descriptor(for:)) + LlamaModelOption.all.map(descriptor(for:))
    }

    /// Descriptor for any model id — catalog, custom repo, or imported.
    static func descriptor(forId id: String, installation: ModelInstallation? = nil) -> ModelDescriptor {
        if let llama = LlamaModelOption.find(id: id) { return descriptor(for: llama) }
        if let whisper = WhisperModelOption.all.first(where: { $0.id == id || $0.folderName == id }) {
            return descriptor(for: whisper)
        }
        if let install = installation { return descriptor(for: install) }
        return descriptor(forUnknownId: id)
    }

    // MARK: Whisper (Core ML)

    static func descriptor(for m: WhisperModelOption) -> ModelDescriptor {
        let isDistil = m.folderName.hasPrefix("distil-whisper_")
        // Distil-Whisper's large-v3 distillations are English-only; the plain
        // Whisper checkpoints are multilingual unless the folder carries ".en".
        let languages: [String]
        let languageSource: String
        if m.englishOnly || isDistil {
            languages = ModelLanguageSets.englishOnly
            languageSource = isDistil
                ? "Distil-Whisper model card (English-only distillation)"
                : "Whisper model card (English-only checkpoint)"
        } else if m.folderName.contains("large-v3") {
            // large-v3 added Cantonese to the multilingual set.
            languages = ModelLanguageSets.whisperMultilingualV3
            languageSource = "Whisper model card (large-v3)"
        } else {
            languages = ModelLanguageSets.whisperMultilingual
            languageSource = "Whisper model card"
        }

        let quant: String? = m.params.contains("quantized")
            ? quantizationLabel(from: m.folderName)
            : nil

        let provider: String
        let handle: String
        if isDistil {
            provider = "Distil-Whisper"; handle = "distil-whisper"
        } else {
            provider = "OpenAI"; handle = "openai"
        }

        return ModelDescriptor(
            id: m.id,
            displayName: "Whisper " + m.display,
            provider: provider,
            providerHandle: handle,
            repositoryId: "argmaxinc/whisperkit-coreml",
            repositoryURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!,
            revision: nil,
            folderName: m.folderName,
            engine: .whisperKit,
            format: .coreML,
            // Whisper on WhisperKit is the combination this app is built and
            // tested around.
            trust: .verified,
            license: "apache-2.0",
            packagerNote: "Core ML build by Argmax",
            capabilities: ModelCapabilities(
                languages: languages,
                languageSource: languageSource,
                speechToText: true,
                // Whisper's translate task targets English only.
                translation: !m.englishOnly && !isDistil,
                timestamps: true,
                wordTimestamps: true,
                streaming: true,
                diarization: false
            ),
            resources: ModelResources(
                parameterCount: m.params.replacingOccurrences(of: " (quantized)", with: ""),
                diskBytes: ModelCatalog.shared.sizeByFolder[m.folderName]
                    ?? Transcriber.parseSizeLabel(m.size),
                memoryBytes: Transcriber.parseSizeLabel(m.ram),
                quantization: quant
            ),
            accuracy: RatedMetric(
                display: "WER \(m.englishWER)",
                fraction: m.accuracyFraction,
                provenance: .published
            ),
            speed: RatedMetric(
                display: m.speedLabel,
                fraction: m.speedFraction,
                provenance: .published
            ),
            blurb: m.blurb,
            recommendation: m.recommendation,
            isBuiltIn: true
        )
    }

    /// "openai_whisper-large-v3_turbo_954MB" → "954 MB build".
    private static func quantizationLabel(from folder: String) -> String? {
        guard let range = folder.range(of: #"_\d+MB$"#, options: .regularExpression) else { return nil }
        let raw = folder[range].dropFirst()          // "954MB"
        return raw.replacingOccurrences(of: "MB", with: " MB build")
    }

    // MARK: Qwen3-ASR (GGUF)

    static func descriptor(for m: LlamaModelOption) -> ModelDescriptor {
        ModelDescriptor(
            id: m.id,
            displayName: m.display,
            provider: m.makerDisplay,
            providerHandle: m.makerOrg,
            repositoryId: m.repoId,
            repositoryURL: m.ggufURL,
            revision: nil,
            folderName: nil,
            engine: .llamaCPP,
            format: .gguf,
            trust: .verified,
            license: "apache-2.0",
            packagerNote: "GGUF by ggml-org",
            capabilities: ModelCapabilities(
                languages: ModelLanguageSets.qwen3ASR,
                languageSource: "Qwen3-ASR model card",
                speechToText: true,
                translation: false,
                timestamps: false,
                wordTimestamps: false,
                // The llama.cpp backend decodes whole utterances — no partials,
                // so live dictation stays on Whisper.
                streaming: false,
                diarization: false
            ),
            resources: ModelResources(
                parameterCount: m.display.contains("0.6B") ? "0.6B" : "1.7B",
                diskBytes: m.sizeBytes,
                memoryBytes: m.ramBytes,
                quantization: m.quant
            ),
            // Qwen3-ASR publishes no per-model English WER table, so no
            // accuracy number is invented for it.
            accuracy: .unknown,
            speed: .unknown,
            blurb: m.blurb,
            recommendation: m.recommendation,
            isBuiltIn: true
        )
    }

    // MARK: Installed custom / imported models

    static func descriptor(for install: ModelInstallation) -> ModelDescriptor {
        let handle = install.repositoryId.split(separator: "/").first.map(String.init)
            ?? install.provider
        let url = install.source == .imported
            ? URL(fileURLWithPath: install.installedPath)
            : URL(string: "https://huggingface.co/\(install.repositoryId)")!
        return ModelDescriptor(
            id: install.id,
            displayName: install.displayName,
            provider: install.provider,
            providerHandle: handle,
            repositoryId: install.repositoryId,
            repositoryURL: url,
            revision: install.pinnedRevision ?? install.commitSha,
            folderName: install.folderName,
            engine: install.engine,
            format: install.format,
            trust: install.source == .imported ? .custom : .community,
            license: install.license,
            packagerNote: nil,
            capabilities: ModelCapabilities(
                languages: install.languages,
                languageSource: install.languages.isEmpty ? nil : "Repository metadata",
                speechToText: true,
                translation: false,
                timestamps: install.engine == .whisperKit,
                wordTimestamps: install.engine == .whisperKit,
                streaming: install.engine == .whisperKit,
                diarization: false
            ),
            resources: ModelResources(
                parameterCount: install.parameterCount,
                diskBytes: install.sizeBytes,
                memoryBytes: install.estimatedMemoryBytes,
                quantization: install.quantization
            ),
            accuracy: .unknown,
            speed: .unknown,
            blurb: install.source == .imported
                ? "Imported from \(install.installedPath)."
                : "Downloaded from the Hugging Face repository \(install.repositoryId).",
            recommendation: "",
            isBuiltIn: false
        )
    }

    // MARK: Discovered repositories

    /// Stage-1 descriptor for a repository found on the Hub (§77): enough to
    /// render a card without fetching the file list. Anything the Hub did not
    /// publish stays unknown and renders as "—" — never as a guess (§13).
    static func descriptor(forHubModel hub: HFHubModel) -> ModelDescriptor {
        let org = hub.author
        // Recognized upstream publishers. "Official" describes who published
        // it, never whether this app has tested it (§ trust).
        let knownOrgs: Set<String> = ["openai", "argmaxinc", "distil-whisper", "qwen", "ggml-org",
                                      "facebook", "nvidia", "microsoft", "mistralai", "google",
                                      "systran", "pyannote", "fluidinference"]
        let format = hub.installability.format
        let engine: ModelEngine = format == .gguf ? .llamaCPP : .whisperKit
        let diskBytes = hub.ggufBytes ?? 0

        return ModelDescriptor(
            id: hub.repoId,
            displayName: hub.displayName,
            provider: org,
            providerHandle: org,
            repositoryId: hub.repoId,
            repositoryURL: hub.repositoryURL,
            revision: nil,
            folderName: nil,
            engine: engine,
            format: format,
            trust: knownOrgs.contains(org.lowercased()) ? .official : .community,
            license: hub.license,
            packagerNote: nil,
            capabilities: ModelCapabilities(
                languages: hub.languages,
                languageSource: hub.languages.isEmpty ? nil : "Hugging Face model card",
                speechToText: true,
                translation: hub.tags.contains { $0.lowercased().contains("translation") },
                timestamps: engine == .whisperKit,
                wordTimestamps: engine == .whisperKit,
                streaming: engine == .whisperKit,
                diarization: hub.tags.contains { $0.lowercased().contains("diariz") }
            ),
            resources: ModelResources(
                parameterCount: hub.parameterLabel,
                diskBytes: diskBytes,
                memoryBytes: diskBytes > 0
                    ? ModelImporter.estimateMemory(diskBytes: diskBytes, engine: engine) : 0,
                quantization: HFRepoMetadata.quantizationHint(hub.name)
            ),
            accuracy: Self.accuracyMetric(from: hub),
            speed: Self.speedMetric(from: hub),
            blurb: Self.blurb(for: hub),
            recommendation: "",
            isBuiltIn: false
        )
    }

    /// The publisher's own WER, mapped onto the app's rating scale with
    /// `published` provenance so the UI can never present it as measured.
    private static func accuracyMetric(from hub: HFHubModel) -> RatedMetric {
        guard let wer = hub.headlineWER else { return .unknown }
        // 2% WER is about as good as speech models get; 30% is unusable.
        let fraction = max(0, min(1, 1 - (wer.value - 2) / 28))
        return RatedMetric(display: String(format: "~%.1f%% WER", wer.value),
                           fraction: fraction, provenance: .published)
    }

    /// The publisher's real-time factor, if they published one.
    private static func speedMetric(from hub: HFHubModel) -> RatedMetric {
        guard let rtfx = hub.headlineSpeed else { return .unknown }
        // 10× real time is respectable, 250× is the fastest published today.
        let fraction = max(0, min(1, log10(max(1, rtfx.value)) / log10(250)))
        return RatedMetric(display: String(format: "~%.0f× real time", rtfx.value),
                           fraction: fraction, provenance: .published)
    }

    private static func blurb(for hub: HFHubModel) -> String {
        var parts: [String] = []
        if let params = hub.parameterLabel { parts.append("\(params)-parameter") }
        parts.append(hub.installability.format.displayName)
        parts.append("speech model")
        var text = parts.joined(separator: " ") + " published by \(hub.author)"
        if let base = hub.baseModels.first, let relation = hub.baseModelRelation {
            text += ", a \(relation) of \(base)"
        }
        return text + "."
    }

    /// Descriptor for one installable build inside a repository.
    static func descriptor(forVariant variant: ModelVariant,
                           in metadata: HFRepoMetadata) -> ModelDescriptor {
        let org = metadata.author
        let engine: ModelEngine = variant.format == .gguf ? .llamaCPP : .whisperKit
        return ModelDescriptor(
            id: variant.id,
            displayName: variant.label,
            provider: org,
            providerHandle: org,
            repositoryId: metadata.repoId,
            repositoryURL: metadata.repositoryURL,
            revision: metadata.sha,
            folderName: variant.format == .coreML ? variant.label : nil,
            engine: engine,
            format: variant.format,
            trust: .community,
            license: metadata.license,
            packagerNote: nil,
            capabilities: ModelCapabilities(
                languages: metadata.languages,
                languageSource: metadata.languages.isEmpty ? nil : "Repository metadata",
                speechToText: true,
                translation: false,
                timestamps: engine == .whisperKit,
                wordTimestamps: engine == .whisperKit,
                streaming: engine == .whisperKit,
                diarization: false
            ),
            resources: ModelResources(
                parameterCount: nil,
                diskBytes: variant.sizeBytes,
                // Labelled as an estimate wherever it appears — the repository
                // doesn't publish a runtime footprint.
                memoryBytes: ModelImporter.estimateMemory(diskBytes: variant.sizeBytes, engine: engine),
                quantization: variant.quantization
            ),
            accuracy: .unknown,
            speed: .unknown,
            blurb: "\(variant.label) build from \(metadata.repoId).",
            recommendation: "",
            isBuiltIn: false
        )
    }

    /// A model id with no catalog entry and no installation record — shown so a
    /// stale `Settings.modelId` never renders as a blank row.
    static func descriptor(forUnknownId id: String) -> ModelDescriptor {
        let custom = WhisperModelOption.parseCustom(id)
        let repo = custom?.repo ?? id
        let folder = custom?.folder
        let name = folder?
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_", with: "") ?? id
        return ModelDescriptor(
            id: id,
            displayName: name,
            provider: repo.split(separator: "/").first.map(String.init) ?? "Unknown",
            providerHandle: repo.split(separator: "/").first.map(String.init) ?? "",
            repositoryId: repo,
            repositoryURL: URL(string: "https://huggingface.co/\(repo)")
                ?? URL(string: "https://huggingface.co")!,
            revision: nil,
            folderName: folder,
            engine: LlamaModelOption.isLlamaId(id) ? .llamaCPP : .whisperKit,
            format: LlamaModelOption.isLlamaId(id) ? .gguf : .coreML,
            trust: .community,
            license: nil,
            packagerNote: nil,
            capabilities: ModelCapabilities(
                languages: [], languageSource: nil, speechToText: true,
                translation: false, timestamps: true, wordTimestamps: true,
                streaming: true, diarization: false
            ),
            resources: ModelResources(parameterCount: nil, diskBytes: 0, memoryBytes: 0, quantization: nil),
            accuracy: .unknown,
            speed: .unknown,
            blurb: "A model from the Hugging Face repository \(repo).",
            recommendation: "",
            isBuiltIn: false
        )
    }
}
