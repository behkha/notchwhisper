import Foundation
import SwiftUI

/// One serial installation queue for every model download in the app.
///
/// This does **not** reimplement transfers: WhisperKit's downloader (via
/// `Transcriber.download`) and `GGUFDownloader` still move the bytes, and both
/// still publish byte-accurate progress to `AppState` — which is what the notch,
/// the menu bar and Home already read. The queue adds the product layer around
/// them: ordering, pause/resume, cancel, retry, post-download verification and
/// the multi-file progress the user actually sees ("3 of 7 files"), so a
/// repository of many files reads as one logical installation (§8).
///
/// One transfer runs at a time. Model downloads are bandwidth- and
/// disk-bound, and a serial queue keeps the byte/ETA figures honest instead of
/// splitting the pipe between jobs and lying about both.
@MainActor
final class ModelDownloadQueue: ObservableObject {
    static let shared = ModelDownloadQueue()

    enum JobState: Equatable {
        case queued
        case running
        case paused
        case verifying
        case failed(String)
        case finished
    }

    struct Job: Identifiable, Equatable {
        let id: String                 // model id
        /// Carried with the job because a discovered model has no catalog entry
        /// and no installation record yet — this is the only place its name,
        /// size and repository live until it lands.
        var descriptor: ModelDescriptor
        var displayName: String
        var totalBytes: Int64
        var bytesDone: Int64 = 0
        var progress: Double = 0
        var speedBps: Double = 0
        var etaSeconds: Double = 0
        var filesDone: Int = 0
        var filesTotal: Int = 0
        var state: JobState = .queued
        /// Re-fetching an already-installed model at a newer revision.
        var isUpdate: Bool = false
        /// Set when the model should become active once it lands.
        var activateOnFinish: Bool = true
        var error: String?
        var enqueuedAt = Date()
        var attempts: Int = 0

        /// "1.25 GB of 1.60 GB · 18.4 MB/s · ~19 s left"
        var detailText: String {
            var parts: [String] = []
            if totalBytes > 0 {
                parts.append("\(Self.bytes(bytesDone)) of \(Self.bytes(totalBytes))")
            } else if bytesDone > 0 {
                parts.append(Self.bytes(bytesDone))
            }
            if speedBps > 1024 { parts.append("\(Self.bytes(Int64(speedBps)))/s") }
            if etaSeconds > 1, totalBytes > 0, bytesDone < totalBytes {
                parts.append("~\(Self.eta(etaSeconds)) left")
            }
            return parts.joined(separator: " · ")
        }

        /// "3 of 7 files" — the logical view of a multi-file repository.
        var fileText: String? {
            guard filesTotal > 1 else { return nil }
            return "\(min(filesDone + 1, filesTotal)) of \(filesTotal) files"
        }

        static func bytes(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
        }
        static func eta(_ seconds: Double) -> String {
            let s = Int(seconds.rounded())
            if s < 60 { return "\(s) s" }
            if s < 3600 { return "\(s / 60) min \(s % 60) s" }
            return "\(s / 3600) h \((s % 3600) / 60) min"
        }
    }

    /// In queue order; the first non-finished job is the one running.
    @Published private(set) var jobs: [Job] = []
    /// Ids whose files are being deleted right now.
    @Published private(set) var removingIds: Set<String> = []
    /// Last completed installation, for the success banner (§85).
    @Published var lastCompleted: (id: String, name: String)?

    private var runner: Task<Void, Never>?
    private var currentTransfer: Task<Bool, Never>?
    private var mirror: Task<Void, Never>?
    /// Set while a job is being paused so the runner can tell a pause from a
    /// genuine failure.
    private var pausingId: String?

    private init() {}

    // MARK: Queries

    func job(for id: String) -> Job? {
        jobs.first { $0.id == id && $0.state != .finished }
    }

    var activeJobs: [Job] { jobs.filter { $0.state != .finished } }
    var activeCount: Int { activeJobs.count }
    var runningJob: Job? { jobs.first { $0.state == .running || $0.state == .verifying } }
    var hasFailures: Bool { jobs.contains { if case .failed = $0.state { return true }; return false } }

    // MARK: Enqueue

    /// Add a model to the install queue. Re-enqueuing something already queued
    /// is a no-op, so a double-click can't start two writers on one file.
    func enqueue(_ descriptor: ModelDescriptor, isUpdate: Bool = false, activate: Bool = true) {
        if let existing = job(for: descriptor.id) {
            // A paused or failed job is resumed rather than duplicated.
            if existing.state == .paused { resume(descriptor.id) }
            if case .failed = existing.state { retry(descriptor.id) }
            return
        }
        var job = Job(
            id: descriptor.id,
            descriptor: descriptor,
            displayName: descriptor.displayName,
            totalBytes: descriptor.resources.diskBytes
        )
        job.isUpdate = isUpdate
        job.activateOnFinish = activate
        jobs.append(job)
        startRunnerIfIdle()
    }

    // MARK: Controls

    func pause(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].state == .running {
            pausingId = id
            currentTransfer?.cancel()
        }
        jobs[index].state = .paused
        jobs[index].speedBps = 0
        jobs[index].etaSeconds = 0
    }

    func resume(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .paused else { return }
        jobs[index].state = .queued
        jobs[index].error = nil
        startRunnerIfIdle()
    }

    func retry(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .queued
        jobs[index].error = nil
        jobs[index].attempts = 0
        startRunnerIfIdle()
    }

    /// Cancel and drop a job. Partial bytes stay on disk so a later download
    /// resumes instead of starting over; "Clear incomplete downloads" in
    /// Storage is the explicit way to reclaim them.
    func cancel(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].state == .running {
            pausingId = id
            currentTransfer?.cancel()
        }
        jobs.remove(at: index)
    }

    func cancelAll() {
        for job in jobs { cancel(job.id) }
    }

    /// Reorder a waiting job. The running job always stays first.
    func move(_ id: String, up: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard jobs.indices.contains(target) else { return }
        guard jobs[target].state == .queued, jobs[index].state == .queued else { return }
        jobs.swapAt(index, target)
    }

    func markRemoving(_ id: String) { removingIds.insert(id) }
    func clearRemoving(_ id: String) { removingIds.remove(id) }

    /// Drop finished rows once the user has seen them.
    func dismissFinished() {
        jobs.removeAll { $0.state == .finished }
        lastCompleted = nil
    }

    // MARK: Runner

    private func startRunnerIfIdle() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.drain()
            self?.runner = nil
        }
    }

    private func drain() async {
        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let id = jobs[index].id
            jobs[index].state = .running
            jobs[index].attempts += 1
            jobs[index].error = nil

            let descriptor = jobs[index].descriptor
            startMirroring(id)

            let transfer = Task<Bool, Never> {
                await Self.runTransfer(modelId: id)
            }
            currentTransfer = transfer
            let ok = await transfer.value
            currentTransfer = nil
            stopMirroring()

            // The job may have been cancelled (removed) while running.
            guard let idx = jobs.firstIndex(where: { $0.id == id }) else {
                pausingId = nil
                continue
            }

            if pausingId == id {
                pausingId = nil
                if jobs[idx].state != .paused { jobs[idx].state = .paused }
                continue
            }

            guard ok else {
                jobs[idx].state = .failed(Self.humanFailure(for: descriptor))
                jobs[idx].error = AppState.shared.statusMessage
                continue
            }

            // §50: verify BEFORE the model is ever treated as installed.
            jobs[idx].state = .verifying
            let verified = await Self.verifyInstalled(descriptor)
            guard let idx2 = jobs.firstIndex(where: { $0.id == id }) else { continue }
            guard verified.ok else {
                jobs[idx2].state = .failed(
                    "The downloaded files are incomplete, so \(descriptor.displayName) wasn't activated."
                )
                await ModelRegistry.shared.scan()
                continue
            }

            ModelRegistry.shared.register(
                descriptor, path: verified.path, sizeBytes: verified.bytes,
                commitSha: descriptor.revision,
                source: descriptor.isBuiltIn ? .builtIn : .huggingFace
            )
            jobs[idx2].state = .finished
            jobs[idx2].progress = 1
            jobs[idx2].bytesDone = jobs[idx2].totalBytes
            lastCompleted = (id, descriptor.displayName)

            if jobs[idx2].activateOnFinish {
                Settings.shared.modelId = id
                _ = await AppDelegate.shared?.transcriberRef.ensureLoaded(modelId: id)
                // Loading is done; this only re-routes the hotkey.
                AppDelegate.shared?.reconcileAfterModelChange()
                ModelRegistry.shared.noteUsed(id)
            }
            await ModelRegistry.shared.scan()
        }
    }

    /// Runs the download through the engine-appropriate existing downloader.
    private static func runTransfer(modelId: String) async -> Bool {
        guard let transcriber = AppDelegate.shared?.transcriberRef else { return false }
        return await transcriber.download(modelId: modelId)
    }

    /// Post-download check: are the files that this runtime needs really there?
    private static func verifyInstalled(_ d: ModelDescriptor) async -> (ok: Bool, path: String, bytes: Int64) {
        let root = ModelStorageLocation.currentRoot
        let folderName = d.folderName
        let engine = d.engine
        let id = d.id
        return await Task.detached(priority: .utility) { () -> (Bool, String, Int64) in
            switch engine {
            case .llamaCPP:
                if let custom = CustomGGUFModel.parse(id) {
                    guard GGUFDownloader.customComplete(custom) else { return (false, "", 0) }
                    return (true, GGUFDownloader.customDir(repoId: custom.repoId).path,
                            GGUFDownloader.customBytes(custom))
                }
                guard let option = LlamaModelOption.find(id: id),
                      GGUFDownloader.isDownloaded(option) else { return (false, "", 0) }
                let dir = GGUFDownloader.dir(for: option)
                return (true, dir.path, GGUFDownloader.onDiskBytes(option))
            case .whisperKit:
                guard let folder = folderName,
                      let url = ModelDisk.findFolder(named: folder, root: root),
                      ModelDisk.hasCoreMLWeights(url) else { return (false, "", 0) }
                return (true, url.path, ModelDisk.directoryBytes(url))
            }
        }.value
    }

    private static func humanFailure(for d: ModelDescriptor) -> String {
        "The download of \(d.displayName) was interrupted."
    }

    // MARK: Progress mirroring
    //
    // The downloaders publish byte-accurate progress to AppState (one global
    // transfer at a time). Rather than duplicating that plumbing per job, the
    // running job mirrors it.

    private func startMirroring(_ id: String) {
        stopMirroring()
        mirror = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = AppState.shared
                if let index = self.jobs.firstIndex(where: { $0.id == id }),
                   self.jobs[index].state == .running {
                    self.jobs[index].progress = s.displayProgress
                    self.jobs[index].bytesDone = s.downloadBytesDone
                    if s.downloadBytesTotal > 0 { self.jobs[index].totalBytes = s.downloadBytesTotal }
                    self.jobs[index].speedBps = s.downloadSpeedBps
                    self.jobs[index].etaSeconds = s.downloadEtaSeconds
                    self.jobs[index].filesDone = s.downloadFilesDone
                    self.jobs[index].filesTotal = s.downloadFilesTotal
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func stopMirroring() {
        mirror?.cancel()
        mirror = nil
    }
}
