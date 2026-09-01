import Foundation
import IOKit.ps

// MARK: - Power state

/// Whether the Mac is on battery, so recommendations can account for it (§39).
/// Read from IOKit rather than assumed.
struct PowerState {
    let isOnBattery: Bool
    let hasBattery: Bool
    /// 0…1, or nil on a desktop.
    let charge: Double?

    /// Cached briefly: recommendation scores are recomputed for every visible
    /// model on every render, and power state is an IOKit round trip. It also
    /// doesn't change on a per-frame timescale.
    static var current: PowerState {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 10 { return cached.state }
        let fresh = read()
        cached = (fresh, Date())
        return fresh
    }

    private nonisolated(unsafe) static var cached: (state: PowerState, at: Date)?
    private static let cacheLock = NSLock()

    private static func read() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else {
            return PowerState(isOnBattery: false, hasBattery: false, charge: nil)
        }
        let state = info[kIOPSPowerSourceStateKey] as? String
        let current = info[kIOPSCurrentCapacityKey] as? Int
        let max = info[kIOPSMaxCapacityKey] as? Int
        let charge = (current.map(Double.init)).flatMap { c in
            max.map { Double($0) }.flatMap { m in m > 0 ? c / m : nil }
        }
        return PowerState(
            isOnBattery: state == kIOPSBatteryPowerValue,
            hasBattery: true,
            charge: charge
        )
    }
}

// MARK: - Language profile
//
// §19: rank by the languages the user actually works in. That has to come from
// something real — here, the languages they have selected in Settings, counted
// over time. Nothing is inferred from transcript content.

@MainActor
final class LanguageProfile: ObservableObject {
    static let shared = LanguageProfile()

    /// language code → number of times it has been selected.
    @Published private(set) var counts: [String: Int] = [:]

    private let key = "languageProfileCounts"

    private init() {
        counts = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        // Seed from the current selection so a fresh install still has a signal.
        if counts.isEmpty, let current = Settings.shared.language, !current.isEmpty {
            counts[current.lowercased()] = 1
            persist()
        }
    }

    func record(_ code: String?) {
        guard let code, !code.isEmpty, code.lowercased() != "auto" else { return }
        counts[code.lowercased(), default: 0] += 1
        persist()
    }

    /// The languages the user works in, most used first.
    var preferredLanguages: [String] {
        var codes = counts.sorted { $0.value > $1.value }.map(\.key)
        if let current = Settings.shared.language?.lowercased(), !current.isEmpty,
           !codes.contains(current) {
            codes.insert(current, at: 0)
        }
        return codes
    }

    var hasSignal: Bool { !preferredLanguages.isEmpty }

    /// "Persian, English and Dutch"
    var summary: String? {
        let names = preferredLanguages.prefix(3).map { ModelCapabilities.languageName($0) }
        guard !names.isEmpty else { return nil }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private func persist() { UserDefaults.standard.set(counts, forKey: key) }
}

// MARK: - Recommendation

/// A reason a model was recommended — shown verbatim, so a recommendation can
/// always be audited by the user.
struct RecommendationReason: Identifiable {
    let id = UUID()
    let text: String
}

/// The badges a model can earn. Each is awarded from a stated criterion; none
/// is awarded just because a model is the default (§44).
enum ModelAward: String, CaseIterable, Identifiable {
    case bestForYourMac, bestOverall, fastest, bestAccuracy, smallest, bestMultilingual, bestForYourLanguages
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bestForYourMac:       return "Best for your Mac"
        case .bestOverall:          return "Best overall"
        case .fastest:              return "Fastest"
        case .bestAccuracy:         return "Best accuracy"
        case .smallest:             return "Smallest"
        case .bestMultilingual:     return "Best multilingual"
        case .bestForYourLanguages: return "Best for your languages"
        }
    }

    var symbol: String {
        switch self {
        case .bestForYourMac:       return "sparkles"
        case .bestOverall:          return "star.fill"
        case .fastest:              return "bolt.fill"
        case .bestAccuracy:         return "target"
        case .smallest:             return "arrow.down.right.and.arrow.up.left"
        case .bestMultilingual:     return "globe"
        case .bestForYourLanguages: return "character.bubble"
        }
    }
}

struct ModelRecommendation: Identifiable {
    let award: ModelAward
    let model: ModelDescriptor
    let reasons: [RecommendationReason]
    var id: String { award.rawValue }
}

/// Ranks models against this Mac, the user's languages and measured results.
///
/// Deliberately not a single opaque score in the UI (§54): the ranking exists to
/// order things, and what the user sees are the interpretable dimensions that
/// produced it.
@MainActor
enum ModelRecommender {

    /// A model's overall suitability, 0…1.
    static func score(_ model: ModelDescriptor,
                      hw: HardwareInfo = .current,
                      power: PowerState = .current) -> Double {
        let verdict = ModelCompatibility.verdict(for: model, hw: hw)
        guard !verdict.isBlocking else { return 0 }

        var score = 0.0

        // Fit on this Mac — the dominant term. A model that thrashes memory is
        // not a good recommendation however accurate it is.
        switch verdict {
        case .recommended:     score += 0.34
        case .supported:       score += 0.28
        case .tight:           score += 0.10
        case .needsMoreMemory: score += 0.0
        case .unsupported:     return 0
        }

        // Measured speed beats published speed whenever we have it.
        if let measured = ModelBenchmarkService.shared.result(for: model.id) {
            let rtf = measured.realTimeFactor
            // 0.1× real time → 1.0; 1.5× → 0.
            score += 0.26 * max(0, min(1, (1.5 - rtf) / 1.4))
        } else if let published = model.speed.fraction {
            score += 0.20 * published
        }

        // Accuracy.
        if let accuracy = model.accuracy.fraction {
            score += 0.22 * accuracy
        } else {
            // Unknown accuracy isn't penalised into oblivion, but a model with a
            // published figure legitimately outranks one with none.
            score += 0.11
        }

        // Language coverage of what the user actually works in.
        score += 0.12 * languageCoverage(model)

        // Disk thrift — a mild preference, not a driver.
        if model.resources.diskBytes > 0 {
            let gb = Double(model.resources.diskBytes) / 1_073_741_824
            score += 0.06 * max(0, min(1, (4 - gb) / 4))
        }

        // On battery, weight lighter models: less memory and fewer compute
        // cycles per minute of audio measurably costs less energy.
        if power.isOnBattery, model.resources.memoryBytes > 0 {
            let gb = Double(model.resources.memoryBytes) / 1_073_741_824
            score += 0.06 * max(0, min(1, (4 - gb) / 4))
        }

        // Live dictation only works on a streaming engine; if the user has it
        // on, a non-streaming model is a downgrade for them specifically.
        if Settings.shared.liveDictation, !model.capabilities.streaming {
            score -= 0.15
        }

        return max(0, min(1, score))
    }

    /// Fraction of the user's preferred languages this model covers.
    static func languageCoverage(_ model: ModelDescriptor) -> Double {
        let preferred = LanguageProfile.shared.preferredLanguages
        guard !preferred.isEmpty else {
            // No signal: a broader model is a safer default.
            return model.capabilities.languages.isEmpty
                ? 0.5 : min(1, Double(model.capabilities.languages.count) / 40)
        }
        guard !model.capabilities.languages.isEmpty else { return 0.4 }
        let covered = preferred.filter { model.capabilities.supports(languageCode: $0) }.count
        return Double(covered) / Double(preferred.count)
    }

    /// The single best model for this Mac right now, from a candidate set.
    static func best(from candidates: [ModelDescriptor],
                     hw: HardwareInfo = .current) -> ModelDescriptor? {
        candidates
            .filter { !ModelCompatibility.verdict(for: $0, hw: hw).isBlocking }
            .max { score($0, hw: hw) < score($1, hw: hw) }
    }

    /// Why a model was recommended — every line has to be true of that model.
    static func reasons(for model: ModelDescriptor, hw: HardwareInfo = .current) -> [RecommendationReason] {
        var out: [RecommendationReason] = []
        let compat = ModelCompatibility.evaluate(model, hw: hw)

        if compat.verdict <= .supported {
            out.append(RecommendationReason(text: compat.summary))
        }
        if hw.isAppleSilicon {
            out.append(RecommendationReason(
                text: model.engine == .llamaCPP
                    ? "Runs on the Metal GPU on Apple Silicon"
                    : "Runs on the Neural Engine on Apple Silicon"))
        }
        if let measured = ModelBenchmarkService.shared.result(for: model.id) {
            out.append(RecommendationReason(
                text: "Measured on this Mac: \(measured.rtfLabel) real time, \(measured.processLabel) for \(Int(measured.audioSeconds))s of audio"))
        } else if let speed = model.speed.fraction, speed >= 0.7 {
            out.append(RecommendationReason(text: "Low latency — \(model.speed.display) (published figure)"))
        }
        if let accuracy = model.accuracy.fraction, accuracy >= 0.8 {
            out.append(RecommendationReason(text: "High published accuracy — \(model.accuracy.display)"))
        }
        if let summary = LanguageProfile.shared.summary,
           LanguageProfile.shared.preferredLanguages.allSatisfy({ model.capabilities.supports(languageCode: $0) }) {
            out.append(RecommendationReason(text: "Covers \(summary)"))
        } else if model.capabilities.languages.count > 20 {
            out.append(RecommendationReason(text: "Broad multilingual coverage — \(model.capabilities.languageCountLabel)"))
        }
        if Settings.shared.liveDictation, model.capabilities.streaming {
            out.append(RecommendationReason(text: "Supports live dictation"))
        }
        return out
    }

    // MARK: Awards

    /// Award each badge to the model that actually earns it. A badge with no
    /// qualifying model is simply not awarded.
    static func awards(from candidates: [ModelDescriptor],
                       hw: HardwareInfo = .current) -> [ModelRecommendation] {
        let usable = candidates.filter { !ModelCompatibility.verdict(for: $0, hw: hw).isBlocking }
        guard !usable.isEmpty else { return [] }

        var out: [ModelRecommendation] = []
        var claimed = Set<String>()

        func award(_ kind: ModelAward, _ model: ModelDescriptor?, _ reasons: [String]) {
            guard let model, !claimed.contains(model.id) else { return }
            claimed.insert(model.id)
            out.append(ModelRecommendation(
                award: kind, model: model,
                reasons: reasons.map { RecommendationReason(text: $0) }
            ))
        }

        // Best for this Mac — the overall score.
        if let top = usable.max(by: { score($0, hw: hw) < score($1, hw: hw) }) {
            award(.bestForYourMac, top, self.reasons(for: top, hw: hw).map(\.text))
        }

        // Fastest — measured first, published second.
        let measured = usable.filter { ModelBenchmarkService.shared.result(for: $0.id) != nil }
        if let fastest = measured.min(by: {
            (ModelBenchmarkService.shared.result(for: $0.id)?.realTimeFactor ?? .infinity)
                < (ModelBenchmarkService.shared.result(for: $1.id)?.realTimeFactor ?? .infinity)
        }), let result = ModelBenchmarkService.shared.result(for: fastest.id) {
            award(.fastest, fastest, ["Measured \(result.rtfLabel) real time on this Mac"])
        } else if let fastest = usable.filter({ $0.speed.isKnown })
            .max(by: { ($0.speed.fraction ?? 0) < ($1.speed.fraction ?? 0) }) {
            award(.fastest, fastest, ["\(fastest.speed.display) (published figure)"])
        }

        // Best accuracy — only from models that publish a figure.
        if let accurate = usable.filter({ $0.accuracy.isKnown })
            .max(by: { ($0.accuracy.fraction ?? 0) < ($1.accuracy.fraction ?? 0) }) {
            award(.bestAccuracy, accurate, ["\(accurate.accuracy.display) (published figure)"])
        }

        // Smallest installable download.
        if let smallest = usable.filter({ $0.resources.diskBytes > 0 })
            .min(by: { $0.resources.diskBytes < $1.resources.diskBytes }) {
            award(.smallest, smallest, ["\(smallest.resources.diskLabel) download"])
        }

        // Broadest language coverage.
        if let multi = usable.filter({ $0.capabilities.languages.count > 1 })
            .max(by: { $0.capabilities.languages.count < $1.capabilities.languages.count }) {
            award(.bestMultilingual, multi, [multi.capabilities.languageCountLabel])
        }

        // Best for the languages the user actually uses.
        if LanguageProfile.shared.hasSignal, let summary = LanguageProfile.shared.summary {
            let covering = usable.filter { model in
                LanguageProfile.shared.preferredLanguages.allSatisfy {
                    model.capabilities.supports(languageCode: $0)
                }
            }
            if let best = covering.max(by: { score($0, hw: hw) < score($1, hw: hw) }) {
                award(.bestForYourLanguages, best, ["Covers \(summary)"])
            }
        }

        return out
    }

    // MARK: Battery advice (§39)

    /// A concrete, measured battery suggestion — or nil when nothing can be
    /// said honestly.
    static func batteryAdvice(active: ModelDescriptor,
                              installed: [ModelDescriptor],
                              power: PowerState = .current) -> (model: ModelDescriptor, text: String)? {
        guard power.isOnBattery else { return nil }
        let bench = ModelBenchmarkService.shared
        guard let activeMemory = active.resources.memoryBytes.nonZero else { return nil }

        // Prefer a candidate that is both installed and measurably lighter.
        let lighter = installed.filter {
            $0.id != active.id
                && ($0.resources.memoryBytes.nonZero ?? .max) < activeMemory
                && !ModelCompatibility.verdict(for: $0).isBlocking
        }
        guard let candidate = lighter.max(by: { score($0) < score($1) }) else { return nil }

        // Say something measured when both have been benchmarked; otherwise
        // stick to the memory difference, which is a fact we know.
        if let a = bench.result(for: active.id), let b = bench.result(for: candidate.id),
           b.processSeconds < a.processSeconds {
            let faster = Int(((a.processSeconds - b.processSeconds) / a.processSeconds * 100).rounded())
            return (candidate,
                    "\(candidate.displayName) finished the same audio \(faster)% faster on this Mac and uses \(candidate.resources.memoryLabel) instead of \(active.resources.memoryLabel).")
        }
        return (candidate,
                "\(candidate.displayName) needs about \(candidate.resources.memoryLabel) of memory versus \(active.resources.memoryLabel) for \(active.displayName).")
    }
}

private extension Int64 {
    var nonZero: Int64? { self > 0 ? self : nil }
}
