import Foundation

/// Facts about the Mac running the app, used to validate whether a given
/// Whisper model is a sensible choice on this hardware (req 4).
///
/// Everything here is cheap, synchronous and cached — reading it in a SwiftUI
/// `body` is fine.
struct HardwareInfo {
    /// Physical RAM in bytes.
    let physicalMemory: Int64
    /// Performance + efficiency core count.
    let cpuCores: Int
    /// `hw.model`, e.g. "Mac14,2".
    let modelIdentifier: String
    /// Marketing-ish chip name, best effort ("Apple M2 Pro", "Apple Silicon",
    /// "Intel").
    let chip: String
    /// True on Apple Silicon (arm64). Whisper CoreML models run dramatically
    /// better here; on Intel the large tiers are impractical.
    let isAppleSilicon: Bool

    static let current: HardwareInfo = {
        let pm = Int64(ProcessInfo.processInfo.physicalMemory)
        let cores = ProcessInfo.processInfo.processorCount

        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(cString: buf)
        }

        let model = sysctlString("hw.model")
        var brand = sysctlString("machdep.cpu.brand_string")

        #if arch(arm64)
        let appleSilicon = true
        if brand.isEmpty { brand = "Apple Silicon" }
        #else
        // Rosetta reports arm64 too; fall back to the brand string / sysctl flag.
        var isARM: Int32 = 0
        var s = MemoryLayout<Int32>.size
        _ = sysctlbyname("hw.optional.arm64", &isARM, &s, nil, 0)
        let appleSilicon = isARM == 1
        if brand.isEmpty { brand = appleSilicon ? "Apple Silicon" : "Intel" }
        #endif

        return HardwareInfo(
            physicalMemory: pm,
            cpuCores: cores,
            modelIdentifier: model,
            chip: brand,
            isAppleSilicon: appleSilicon
        )
    }()

    var memoryGB: Double { Double(physicalMemory) / 1_073_741_824 }

    /// Free space on the volume holding the models (for download feasibility
    /// checks).
    ///
    /// Cached for a few seconds: compatibility is evaluated for every visible
    /// model on every render, and a filesystem query per card per frame is a
    /// cost the Models page shouldn't pay. Free space doesn't move fast enough
    /// for the staleness to matter, and the pre-download check re-reads it.
    static func freeDiskBytes(maxAge: TimeInterval = 5) -> Int64 {
        diskCacheLock.lock()
        defer { diskCacheLock.unlock() }
        if let cached = cachedFreeDisk, Date().timeIntervalSince(cached.at) < maxAge {
            return cached.bytes
        }
        let url = ModelStorageLocation.currentRoot
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        cachedFreeDisk = (bytes, Date())
        return bytes
    }

    private nonisolated(unsafe) static var cachedFreeDisk: (bytes: Int64, at: Date)?
    private static let diskCacheLock = NSLock()

    var summary: String {
        let gb = memoryGB
        let mem = gb >= 1 ? String(format: "%.0f GB", gb.rounded()) : String(format: "%.1f GB", gb)
        return "\(chip) · \(mem) RAM · \(cpuCores) cores"
    }
}

/// How well a model is expected to run on the current Mac.
enum ModelFit: Int, Comparable {
    case great          // comfortably within resources
    case ok             // works, some headroom
    case tight          // will run but memory pressure / slow
    case notRecommended // exceeds practical limits for this Mac

    static func < (a: ModelFit, b: ModelFit) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .great:          return "Runs great"
        case .ok:             return "Runs well"
        case .tight:          return "Tight fit"
        case .notRecommended: return "Not recommended"
        }
    }

    var symbol: String {
        switch self {
        case .great:          return "checkmark.seal.fill"
        case .ok:             return "checkmark.circle.fill"
        case .tight:          return "exclamationmark.triangle.fill"
        case .notRecommended: return "xmark.octagon.fill"
        }
    }
}

extension WhisperModelOption {

    /// Parse the `ram` label ("~2.1 GB", "~390 MB") into bytes.
    var runtimeRAMBytes: Int64 { Transcriber.parseSizeLabel(ram) }

    /// Validate this model against the given hardware.
    ///
    /// Rule of thumb: a CoreML Whisper model needs its weights resident plus
    /// working buffers, and the OS + other apps need room too. We compare the
    /// model's runtime RAM estimate against a budget of ~55% of physical RAM
    /// (what a background utility can reasonably claim without paging the
    /// user's foreground app), and knock the rating down a step on Intel where
    /// the Neural Engine isn't available.
    func fit(on hw: HardwareInfo = .current) -> ModelFit {
        let ram = runtimeRAMBytes
        guard ram > 0 else { return .ok }

        let budget = Double(hw.physicalMemory) * 0.55
        let ratio = Double(ram) / budget

        var fit: ModelFit
        switch ratio {
        case ..<0.45: fit = .great
        case ..<0.75: fit = .ok
        case ..<1.05: fit = .tight
        default:      fit = .notRecommended
        }

        // Intel Macs have no ANE; the medium/large tiers are painfully slow.
        if !hw.isAppleSilicon, speedFactor <= 2 {
            fit = ModelFit(rawValue: max(fit.rawValue, ModelFit.tight.rawValue)) ?? .tight
        }
        return fit
    }

    /// A one-line, plain-language verdict for this Mac.
    func fitExplanation(on hw: HardwareInfo = .current) -> String {
        switch fit(on: hw) {
        case .great:
            return "Comfortably within your \(memGB(hw)) of RAM — a good match for this Mac."
        case .ok:
            return "Runs well on your \(memGB(hw)) of RAM with room to spare for other apps."
        case .tight:
            return hw.isAppleSilicon
                ? "Uses a large share of your \(memGB(hw)) of RAM — expect memory pressure while other apps are open."
                : "Heavy for an Intel Mac without a Neural Engine — transcription will be slow."
        case .notRecommended:
            return "Needs more memory than your \(memGB(hw)) Mac can spare — pick a smaller or quantized model."
        }
    }

    private func memGB(_ hw: HardwareInfo) -> String {
        let gb = hw.memoryGB
        return gb >= 1 ? String(format: "%.0f GB", gb.rounded()) : String(format: "%.1f GB", gb)
    }
}

extension LlamaModelOption {

    /// Validate this GGUF Qwen3-ASR model against the current Mac. llama.cpp
    /// runs it on the Metal GPU; the practical limits are RAM and Apple Silicon.
    func fit(on hw: HardwareInfo = .current) -> ModelFit {
        guard hw.isAppleSilicon else { return .notRecommended }
        let gb = hw.memoryGB
        if gb + 0.5 < Double(minRAMGB) { return .notRecommended }
        let budget = Double(hw.physicalMemory) * 0.55
        switch Double(ramBytes) / budget {
        case ..<0.45: return .great
        case ..<0.75: return .ok
        case ..<1.05: return .tight
        default:      return .notRecommended
        }
    }

    func fitExplanation(on hw: HardwareInfo = .current) -> String {
        let mem = hw.memoryGB >= 1
            ? String(format: "%.0f GB", hw.memoryGB.rounded())
            : String(format: "%.1f GB", hw.memoryGB)
        switch fit(on: hw) {
        case .great:          return "Comfortably within your \(mem) of RAM — runs well on this Mac."
        case .ok:             return "Runs well on your \(mem) of RAM with room for other apps."
        case .tight:          return "Uses a large share of your \(mem) of RAM — expect memory pressure."
        case .notRecommended:
            return hw.isAppleSilicon
                ? "Needs about \(minRAMGB) GB of RAM — more than your \(mem) Mac can spare. Pick a smaller Qwen3-ASR build."
                : "Qwen3-ASR runs only on Apple Silicon Macs."
        }
    }
}
