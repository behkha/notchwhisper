import Foundation
import SwiftUI

// MARK: - Local metrics
//
// Everything here is measured on this Mac and stored on this Mac. No audio,
// transcript or timing ever leaves the machine (§89, §90).

/// Process footprint and CPU time, read from the kernel rather than guessed.
enum ProcessMetrics {

    /// Physical footprint in bytes — the figure Activity Monitor shows.
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    /// Total CPU seconds this process has consumed across all threads.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

// MARK: - Benchmark sample
//
// A benchmark is only comparable if every model hears the same audio, so the
// sample is captured once and reused. It stays on disk as raw 16 kHz mono
// float32 — the format every engine in the app already consumes.

struct BenchmarkSample: Codable, Equatable {
    var createdAt: Date
    var sampleCount: Int
    var sourceName: String
    /// Optional ground truth the user typed, enabling a real WER figure.
    var referenceTranscript: String?

    var durationSeconds: Double { Double(sampleCount) / 16_000 }
    var durationLabel: String { AudioFileImport.durationLabel(seconds: durationSeconds) }
}

/// One measured run of one model.
struct BenchmarkResult: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var modelId: String
    var modelName: String
    var ranAt: Date
    var audioSeconds: Double
    /// Time to get the model resident (0 when it was already loaded).
    var loadSeconds: Double
    /// Wall-clock decode time.
    var processSeconds: Double
    /// Time to the first partial result, when the engine reports one.
    var firstResultSeconds: Double?
    var peakFootprintBytes: Int64
    /// Average CPU utilisation across all cores during the decode, 0…1.
    var cpuUtilisation: Double
    var transcript: String
    /// Word error rate against the sample's reference transcript, when set.
    var wordErrorRate: Double?
    var machineSummary: String

    /// Real-time factor: <1 means faster than real time.
    var realTimeFactor: Double {
        audioSeconds > 0 ? processSeconds / audioSeconds : 0
    }

    var rtfLabel: String { String(format: "%.2f×", realTimeFactor) }
    var processLabel: String { String(format: "%.1f s", processSeconds) }
    var loadLabel: String { String(format: "%.2f s", loadSeconds) }
    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: peakFootprintBytes, countStyle: .file)
    }
    var cpuLabel: String { String(format: "%.0f%%", cpuUtilisation * 100) }
    var werLabel: String? { wordErrorRate.map { String(format: "%.1f%%", $0 * 100) } }

    /// A plain-language verdict, stated only from what was measured.
    var verdict: String {
        let rtf = realTimeFactor
        if rtf <= 0 { return "" }
        if rtf < 0.25 { return "Excellent for real-time dictation" }
        if rtf < 0.6 { return "Comfortable for real-time dictation" }
        if rtf < 1.0 { return "Keeps up with real time" }
        return "Slower than real time — best for finished recordings"
    }
}

/// Per-model usage totals, all local (§41).
struct ModelUsageStats: Codable, Equatable {
    var sessions: Int = 0
    var transcribedSeconds: Double = 0
    var totalProcessingSeconds: Double = 0
    var failures: Int = 0
    var lastUsed: Date?
    var peakFootprintBytes: Int64 = 0

    var averageProcessingSeconds: Double {
        sessions > 0 ? totalProcessingSeconds / Double(sessions) : 0
    }
    var averageRTF: Double? {
        guard transcribedSeconds > 0, totalProcessingSeconds > 0 else { return nil }
        return totalProcessingSeconds / transcribedSeconds
    }
    var transcribedLabel: String {
        let total = Int(transcribedSeconds.rounded())
        if total < 60 { return "\(total)s" }
        let (h, m) = (total / 3600, (total % 3600) / 60)
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Service

@MainActor
final class ModelBenchmarkService: ObservableObject {
    static let shared = ModelBenchmarkService()

    /// Most recent result per model id.
    @Published private(set) var results: [String: BenchmarkResult] = [:]
    /// Full history, newest first (kept small).
    @Published private(set) var history: [BenchmarkResult] = []
    @Published private(set) var usage: [String: ModelUsageStats] = [:]
    @Published private(set) var sample: BenchmarkSample?
    @Published private(set) var runningModelId: String?
    @Published private(set) var phase: String = ""
    @Published var lastError: String?

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/Benchmark", isDirectory: true)
    }
    private var sampleAudioURL: URL { folder.appendingPathComponent("sample.pcm") }
    private var storeURL: URL { folder.appendingPathComponent("benchmarks.json") }

    private struct Store: Codable {
        var history: [BenchmarkResult] = []
        var usage: [String: ModelUsageStats] = [:]
        var sample: BenchmarkSample?
    }

    private init() { load() }

    var hasSample: Bool { sample != nil && FileManager.default.fileExists(atPath: sampleAudioURL.path) }
    var isRunning: Bool { runningModelId != nil }

    func result(for modelId: String) -> BenchmarkResult? { results[modelId] }
    func stats(for modelId: String) -> ModelUsageStats? { usage[modelId] }

    /// Benchmarked models ranked fastest-first — the "Your Mac" table (§20).
    var leaderboard: [BenchmarkResult] {
        results.values.sorted { $0.processSeconds < $1.processSeconds }
    }

    // MARK: Sample management

    enum BenchmarkError: LocalizedError {
        case noSample
        case busy
        case tooShort
        case notInstalled(String)
        case loadFailed(String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSample:
                return "Record or import a short audio sample first — every model is timed on the same audio so the numbers are comparable."
            case .busy:
                return "Finish the recording that's in progress, then run the benchmark."
            case .tooShort:
                return "That sample is under two seconds. Use at least a few seconds of speech for a meaningful measurement."
            case .notInstalled(let name):
                return "\(name) isn't installed yet."
            case .loadFailed(let why):
                return "The model couldn't be loaded: \(why)"
            case .decodeFailed(let why):
                return "Transcription failed: \(why)"
            }
        }
    }

    /// Store the audio every benchmark will use.
    func setSample(_ samples: [Float], sourceName: String, reference: String? = nil) throws {
        guard samples.count > 32_000 else { throw BenchmarkError.tooShort }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: sampleAudioURL)
        sample = BenchmarkSample(
            createdAt: Date(), sampleCount: samples.count,
            sourceName: sourceName, referenceTranscript: reference
        )
        // A new sample invalidates comparisons against the old one.
        results = [:]
        history = []
        save()
    }

    func setReferenceTranscript(_ text: String?) {
        guard var sample else { return }
        sample.referenceTranscript = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sample = sample
        save()
    }

    /// Delete the stored benchmark audio (§89 — the user can always take it back).
    func deleteSample() {
        try? FileManager.default.removeItem(at: sampleAudioURL)
        sample = nil
        results = [:]
        history = []
        save()
    }

    private func loadSampleAudio() -> [Float]? {
        guard let data = try? Data(contentsOf: sampleAudioURL), !data.isEmpty else { return nil }
        // Copy rather than rebind: file-backed Data carries no alignment
        // guarantee, and a misaligned Float load is undefined behaviour.
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        guard !out.isEmpty else { return nil }
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    // MARK: Running

    /// Time one model on the stored sample.
    ///
    /// The previously active model is restored afterwards, so benchmarking
    /// never silently leaves the user dictating with a different engine.
    @discardableResult
    func run(modelId: String) async throws -> BenchmarkResult {
        guard let transcriber = AppDelegate.shared?.transcriberRef else {
            throw BenchmarkError.loadFailed("the engine isn't available")
        }
        guard !isRunning else { throw BenchmarkError.busy }
        guard AppState.shared.mode == .idle else { throw BenchmarkError.busy }
        guard ModelRegistry.shared.installedIds.contains(modelId) else {
            throw BenchmarkError.notInstalled(ModelRegistry.shared.descriptor(for: modelId).displayName)
        }
        guard let samples = loadSampleAudio(), let sample else { throw BenchmarkError.noSample }

        let descriptor = ModelRegistry.shared.descriptor(for: modelId)
        let previouslyActive = Settings.shared.modelId
        runningModelId = modelId
        lastError = nil
        defer { runningModelId = nil; phase = "" }

        // 1. Load.
        phase = "Loading \(descriptor.displayName)…"
        let loadStart = Date()
        guard await transcriber.ensureLoaded(modelId: modelId) else {
            // Put the user's engine back before surfacing the failure.
            if previouslyActive != modelId { _ = await transcriber.ensureLoaded(modelId: previouslyActive) }
            throw BenchmarkError.loadFailed(AppState.shared.statusMessage.nilIfEmpty ?? "unknown error")
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)

        // 2. Decode, sampling footprint and CPU time throughout.
        phase = "Transcribing \(sample.durationLabel) of audio…"
        let peak = PeakFootprintSampler()
        peak.start()
        let cpuBefore = ProcessMetrics.cpuSeconds()
        let firstResult = FirstResultClock()
        let decodeStart = Date()
        let transcript: String
        do {
            transcript = try await transcriber.transcribeFile(
                samples,
                biasTerms: [],
                isCancelled: { false },
                onProgress: { _ in firstResult.mark() }
            )
        } catch {
            peak.stop()
            if previouslyActive != modelId { _ = await transcriber.ensureLoaded(modelId: previouslyActive) }
            throw BenchmarkError.decodeFailed(error.localizedDescription)
        }
        let processSeconds = Date().timeIntervalSince(decodeStart)
        let cpuUsed = ProcessMetrics.cpuSeconds() - cpuBefore
        let peakBytes = peak.stop()

        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let utilisation = processSeconds > 0
            ? min(1, cpuUsed / (processSeconds * cores)) : 0

        let result = BenchmarkResult(
            modelId: modelId,
            modelName: descriptor.displayName,
            ranAt: Date(),
            audioSeconds: sample.durationSeconds,
            loadSeconds: loadSeconds,
            processSeconds: processSeconds,
            firstResultSeconds: firstResult.elapsed(since: decodeStart),
            peakFootprintBytes: peakBytes,
            cpuUtilisation: utilisation,
            transcript: transcript,
            wordErrorRate: sample.referenceTranscript.map {
                Self.wordErrorRate(reference: $0, hypothesis: transcript)
            },
            machineSummary: HardwareInfo.current.summary
        )

        results[modelId] = result
        history.insert(result, at: 0)
        if history.count > 60 { history = Array(history.prefix(60)) }
        save()

        // 3. Restore the engine the user was on.
        if previouslyActive != modelId {
            phase = "Restoring \(ModelRegistry.shared.descriptor(for: previouslyActive).displayName)…"
            _ = await transcriber.ensureLoaded(modelId: previouslyActive)
        }
        return result
    }

    /// Run the same sample through several models, in order.
    func runComparison(modelIds: [String]) async -> [BenchmarkResult] {
        var out: [BenchmarkResult] = []
        for id in modelIds {
            do { out.append(try await run(modelId: id)) }
            catch { lastError = error.localizedDescription }
        }
        return out
    }

    // MARK: Usage recording (called from the dictation pipeline)

    func recordUsage(modelId: String, audioSeconds: Double, processingSeconds: Double, failed: Bool = false) {
        var stats = usage[modelId] ?? ModelUsageStats()
        stats.sessions += 1
        stats.transcribedSeconds += max(0, audioSeconds)
        stats.totalProcessingSeconds += max(0, processingSeconds)
        if failed { stats.failures += 1 }
        stats.lastUsed = Date()
        stats.peakFootprintBytes = max(stats.peakFootprintBytes, ProcessMetrics.footprintBytes())
        usage[modelId] = stats
        save()
    }

    // MARK: WER

    /// Word error rate: edit distance over words ÷ reference length. Only ever
    /// shown when the user supplied a reference transcript for their sample.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return 0 }
        guard !h.isEmpty else { return 1 }
        var previous = Array(0...h.count)
        var current = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            current[0] = i
            for j in 1...h.count {
                let cost = r[i - 1] == h[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return min(1, Double(previous[h.count]) / Double(r.count))
    }

    // MARK: Persistence

    private func save() {
        let store = Store(history: history, usage: usage, sample: sample)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: storeURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        history = store.history
        usage = store.usage
        sample = store.sample
        // Newest result wins per model.
        var latest: [String: BenchmarkResult] = [:]
        for result in store.history.sorted(by: { $0.ranAt < $1.ranAt }) {
            latest[result.modelId] = result
        }
        results = latest
        // A sample record without its audio is stale (e.g. the folder was
        // cleared) — drop it rather than offering a benchmark that can't run.
        if sample != nil, !FileManager.default.fileExists(atPath: sampleAudioURL.path) {
            sample = nil
        }
    }
}

// MARK: - Samplers

/// Polls the process footprint on a background queue and reports the peak.
private final class PeakFootprintSampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var peak: Int64 = 0
    private let lock = NSLock()

    func start() {
        peak = ProcessMetrics.footprintBytes()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nw.benchmark.footprint"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessMetrics.footprintBytes()
            self.lock.lock()
            if now > self.peak { self.peak = now }
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

/// Records when the engine first reported progress — the user-visible "first
/// words appear" latency.
private final class FirstResultClock: @unchecked Sendable {
    private var at: Date?
    private let lock = NSLock()

    func mark() {
        lock.lock(); defer { lock.unlock() }
        if at == nil { at = Date() }
    }

    func elapsed(since start: Date) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return at.map { $0.timeIntervalSince(start) }
    }
}
