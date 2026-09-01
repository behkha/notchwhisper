import Foundation
import SwiftUI

// MARK: - Persistent installation record
//
// §25: installation state is local and durable, and is NOT derived from remote
// Hugging Face metadata. A model stays installed and usable whether or not the
// Hub is reachable.

/// What the app recorded when it installed a model.
struct ModelInstallation: Codable, Identifiable, Hashable {
    /// Matches `Settings.modelId`.
    var id: String
    var repositoryId: String
    /// Commit the files were fetched from, when the Hub reported one.
    var commitSha: String?
    /// Set when the user pins this model to a revision (§32).
    var pinnedRevision: String?
    var displayName: String
    var provider: String
    var source: Source
    var format: ModelFileFormat
    var engine: ModelEngine
    var quantization: String?
    var languages: [String]
    var parameterCount: String?
    var license: String?
    var sizeBytes: Int64
    var estimatedMemoryBytes: Int64
    /// Absolute path of the installed model directory.
    var installedPath: String
    /// Core ML folder name inside the repository (Whisper only).
    var folderName: String?
    var installedAt: Date
    var lastUsedAt: Date?
    var usageCount: Int
    var verification: Verification
    var isFavorite: Bool

    enum Source: String, Codable {
        case builtIn        // shipped catalog
        case huggingFace    // discovered on the Hub
        case imported       // brought in from disk
    }

    enum Verification: String, Codable {
        case verified       // files present and complete after install
        case unverified     // never checked (e.g. migrated from an older build)
        case failed         // checked and found incomplete
    }
}

// MARK: - Lifecycle
//
// §7 / §25: every model has one clear state, communicated with BOTH a glyph and
// words — never colour alone (§57).

enum ModelLifecycle: Equatable {
    case available                   // known, not installed
    case queued                      // waiting behind another download
    case downloading(Double)         // 0…1
    case paused(Double)
    case verifying
    case installed
    case active
    case updating
    case failed(String)
    case corrupted
    case incompatible(String)
    case removing

    var label: String {
        switch self {
        case .available:        return "Available"
        case .queued:           return "Queued"
        case .downloading:      return "Downloading"
        case .paused:           return "Paused"
        case .verifying:        return "Verifying"
        case .installed:        return "Ready"
        case .active:           return "Active"
        case .updating:         return "Updating"
        case .failed:           return "Download failed"
        case .corrupted:        return "Needs repair"
        case .incompatible:     return "Not supported"
        case .removing:         return "Removing"
        }
    }

    /// A glyph that reads on its own, so status never depends on colour.
    var symbol: String {
        switch self {
        case .available:        return "arrow.down.circle"
        case .queued:           return "clock"
        case .downloading:      return "arrow.down.circle.fill"
        case .paused:           return "pause.circle.fill"
        case .verifying:        return "checklist"
        case .installed:        return "checkmark.circle"
        case .active:           return "checkmark.circle.fill"
        case .updating:         return "arrow.triangle.2.circlepath"
        case .failed:           return "xmark.circle.fill"
        case .corrupted:        return "exclamationmark.triangle.fill"
        case .incompatible:     return "xmark.octagon.fill"
        case .removing:         return "trash"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .installed, .active, .updating, .verifying: return true
        default: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .queued, .downloading, .verifying, .updating, .removing: return true
        default: return false
        }
    }

    /// The one primary action label for this state (§6).
    var primaryActionLabel: String {
        switch self {
        case .available:    return "Download"
        case .queued:       return "Queued"
        case .downloading:  return "Downloading…"
        case .paused:       return "Resume"
        case .verifying:    return "Verifying…"
        case .installed:    return "Use"
        case .active:       return "Active"
        case .updating:     return "Updating…"
        case .failed:       return "Retry"
        case .corrupted:    return "Repair"
        case .incompatible: return "Details"
        case .removing:     return "Removing…"
        }
    }
}

// MARK: - Registry

/// The single source of truth for what is installed, what is active, and what
/// state everything is in.
///
/// It sits on top of the existing primitives rather than replacing them:
/// `Settings.modelId` remains the active-model identity, `ModelDisk` remains
/// the disk truth, and downloads still run through `Transcriber`/`GGUFDownloader`
/// by way of `ModelDownloadQueue`.
@MainActor
final class ModelRegistry: ObservableObject {
    static let shared = ModelRegistry()

    /// Persisted installation records, keyed by model id.
    @Published private(set) var installations: [String: ModelInstallation] = [:]
    /// Models discovered on the Hub this session (not installed).
    @Published var discovered: [ModelDescriptor] = []
    /// Rebuilt whenever disk truth is re-scanned; views observe this.
    @Published private(set) var installedIds: Set<String> = []
    /// Model ids whose files exist but are incomplete.
    @Published private(set) var corruptedIds: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    /// False until the first disk scan completes. "No models installed" and
    /// "we haven't looked yet" are different states, and showing the first-run
    /// screen for the second one makes the page flash on every launch.
    @Published private(set) var hasScanned = false

    private let settings = Settings.shared
    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/installed-models.json")
    }

    private init() {
        load()
        Task { await scan() }
    }

    // MARK: Active / default

    var activeId: String { settings.modelId }

    /// The model each new dictation starts with when nothing overrides it (§37 —
    /// distinct from the active model and from the most recently used one).
    var defaultId: String {
        get { UserDefaults.standard.string(forKey: "defaultModelId") ?? settings.modelId }
        set { UserDefaults.standard.set(newValue, forKey: "defaultModelId"); objectWillChange.send() }
    }

    var lastUsedId: String? {
        installations.values
            .filter { $0.lastUsedAt != nil }
            .max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id
    }

    // MARK: Descriptors

    /// Every model the user can see: the shipped catalog, anything installed
    /// that isn't in it, and anything discovered this session.
    var allKnown: [ModelDescriptor] {
        var byId: [String: ModelDescriptor] = [:]
        for d in ModelCatalogService.builtIn { byId[d.id] = d }
        for install in installations.values where byId[install.id] == nil {
            byId[install.id] = ModelCatalogService.descriptor(for: install)
        }
        for d in discovered where byId[d.id] == nil { byId[d.id] = d }
        // A stale active model id must still resolve to something showable.
        if byId[activeId] == nil {
            byId[activeId] = ModelCatalogService.descriptor(forId: activeId,
                                                           installation: installations[activeId])
        }
        return Array(byId.values)
    }

    func descriptor(for id: String) -> ModelDescriptor {
        ModelCatalogService.descriptor(forId: id, installation: installations[id])
    }

    var installedDescriptors: [ModelDescriptor] {
        installedIds.map { descriptor(for: $0) }
            .sorted { lhs, rhs in
                if (lhs.id == activeId) != (rhs.id == activeId) { return lhs.id == activeId }
                let lf = isFavorite(lhs.id), rf = isFavorite(rhs.id)
                if lf != rf { return lf }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    // MARK: Lifecycle resolution

    /// The single place any view asks "what state is this model in?".
    func lifecycle(of id: String, compatibility: ModelCompatibility? = nil) -> ModelLifecycle {
        let queue = ModelDownloadQueue.shared
        if queue.removingIds.contains(id) { return .removing }
        if let job = queue.job(for: id) {
            switch job.state {
            case .queued:            return .queued
            case .running:           return job.isUpdate ? .updating : .downloading(job.progress)
            case .paused:            return .paused(job.progress)
            case .verifying:         return .verifying
            case .failed(let why):   return .failed(why)
            case .finished:          break
            }
        }
        if corruptedIds.contains(id) { return .corrupted }
        if installedIds.contains(id) {
            return id == activeId ? .active : .installed
        }
        // Only the verdict is needed here; the full evaluation (with its check
        // list and prose) is built once, in the detail view.
        let verdict = compatibility?.verdict ?? ModelCompatibility.verdict(for: descriptor(for: id))
        if verdict.isBlocking {
            return .incompatible("This model needs a runtime or hardware NotchWhisper doesn't have.")
        }
        return .available
    }

    // MARK: Disk scan
    //
    // Reconciles persisted records against what is actually on disk. Files can
    // vanish behind the app's back (a user emptying a folder, a failed move), so
    // the disk always wins.

    func scan() async {
        isScanning = true
        defer { isScanning = false; lastScan = Date(); hasScanned = true }

        let root = ModelStorageLocation.currentRoot
        let records = installations

        struct ScanResult: Sendable {
            var installed: Set<String> = []
            var corrupted: Set<String> = []
            var sizes: [String: Int64] = [:]
            var paths: [String: String] = [:]
        }

        let result = await Task.detached(priority: .utility) { () -> ScanResult in
            var out = ScanResult()

            // 1. Built-in Whisper catalog.
            for folder in ModelDisk.installedCatalogFolders(root: root) {
                let id = WhisperModelOption.bareId(folder)
                out.installed.insert(id)
                let url = ModelDisk.whisperCatalogRoot(root).appendingPathComponent(folder, isDirectory: true)
                out.sizes[id] = ModelDisk.directoryBytes(url)
                out.paths[id] = url.path
            }
            for folder in ModelDisk.partialCatalogFolders(root: root) {
                out.corrupted.insert(WhisperModelOption.bareId(folder))
            }

            // 2. Built-in GGUF catalog.
            for m in LlamaModelOption.all {
                let dir = GGUFDownloader.dir(for: m)
                if GGUFDownloader.isDownloaded(m) {
                    out.installed.insert(m.id)
                    out.sizes[m.id] = GGUFDownloader.onDiskBytes(m)
                    out.paths[m.id] = dir.path
                } else if GGUFDownloader.onDiskBytes(m) > 0 {
                    out.corrupted.insert(m.id)
                }
            }

            // 3. Recorded custom / imported models — trust the recorded path,
            //    then re-verify its contents.
            for (id, record) in records where record.source != .builtIn {
                let url = URL(fileURLWithPath: record.installedPath, isDirectory: true)
                let complete: Bool
                if let custom = CustomGGUFModel.parse(id) {
                    // A discovered GGUF is complete only with both files and
                    // the completion marker a finished download writes.
                    complete = GGUFDownloader.customComplete(custom)
                    if complete {
                        out.installed.insert(id)
                        out.sizes[id] = GGUFDownloader.customBytes(custom)
                        out.paths[id] = GGUFDownloader.customDir(repoId: custom.repoId).path
                        continue
                    }
                    if GGUFDownloader.customBytes(custom) > 0 { out.corrupted.insert(id) }
                    continue
                }
                switch record.engine {
                case .whisperKit:
                    complete = ModelDisk.hasCoreMLWeights(url)
                case .llamaCPP:
                    complete = ModelDisk.directoryBytes(url) > 0
                }
                if complete {
                    out.installed.insert(id)
                    out.sizes[id] = ModelDisk.directoryBytes(url)
                    out.paths[id] = url.path
                } else if FileManager.default.fileExists(atPath: url.path) {
                    out.corrupted.insert(id)
                } else if let folder = record.folderName,
                          let found = ModelDisk.findFolder(named: folder, root: root),
                          ModelDisk.hasCoreMLWeights(found) {
                    // Relocated (e.g. after a storage migration).
                    out.installed.insert(id)
                    out.sizes[id] = ModelDisk.directoryBytes(found)
                    out.paths[id] = found.path
                }
            }
            return out
        }.value

        installedIds = result.installed
        corruptedIds = result.corrupted

        // Materialize records for anything installed we had no record of, and
        // refresh sizes/paths for the ones we did.
        for id in result.installed {
            if var record = installations[id] {
                record.sizeBytes = result.sizes[id] ?? record.sizeBytes
                if let path = result.paths[id] { record.installedPath = path }
                if record.verification == .failed { record.verification = .verified }
                installations[id] = record
            } else {
                installations[id] = makeRecord(for: descriptor(for: id),
                                               path: result.paths[id] ?? "",
                                               sizeBytes: result.sizes[id] ?? 0)
            }
        }
        for id in result.corrupted {
            installations[id]?.verification = .failed
        }
        // Drop records for models that are no longer anywhere on disk.
        //
        // An imported model is kept even when its files are missing: "use in
        // place" can point at an unmounted volume, and silently forgetting the
        // model would lose the only record of where it came from. It's marked
        // as needing repair instead, which the row explains.
        let known = Set(installations.keys)          // snapshot: the loop mutates
        for id in known where !result.installed.contains(id) && !result.corrupted.contains(id) {
            if installations[id]?.source == .imported {
                installations[id]?.verification = .failed
                corruptedIds.insert(id)
            } else {
                installations.removeValue(forKey: id)
            }
        }
        persist()
    }

    private func makeRecord(for d: ModelDescriptor, path: String, sizeBytes: Int64) -> ModelInstallation {
        ModelInstallation(
            id: d.id,
            repositoryId: d.repositoryId,
            commitSha: nil,
            pinnedRevision: d.revision,
            displayName: d.displayName,
            provider: d.provider,
            source: d.isBuiltIn ? .builtIn : .huggingFace,
            format: d.format,
            engine: d.engine,
            quantization: d.resources.quantization,
            languages: d.capabilities.languages,
            parameterCount: d.resources.parameterCount,
            license: d.license,
            sizeBytes: sizeBytes > 0 ? sizeBytes : d.resources.diskBytes,
            estimatedMemoryBytes: d.resources.memoryBytes,
            installedPath: path,
            folderName: d.folderName,
            installedAt: Date(),
            lastUsedAt: nil,
            usageCount: 0,
            verification: .verified,
            isFavorite: false
        )
    }

    /// Called by the installer once a download completed and verified.
    func register(_ descriptor: ModelDescriptor, path: String, sizeBytes: Int64,
                  commitSha: String? = nil, source: ModelInstallation.Source? = nil) {
        var record = installations[descriptor.id]
            ?? makeRecord(for: descriptor, path: path, sizeBytes: sizeBytes)
        record.installedPath = path
        record.sizeBytes = sizeBytes > 0 ? sizeBytes : record.sizeBytes
        record.commitSha = commitSha ?? record.commitSha
        record.verification = .verified
        if let source { record.source = source }
        installations[descriptor.id] = record
        installedIds.insert(descriptor.id)
        corruptedIds.remove(descriptor.id)
        persist()
    }

    /// Register a model the user imported from disk. Kept separate from
    /// `register(_:path:…)` because an import carries its own metadata instead
    /// of resolving against a catalog entry.
    func registerImported(_ record: ModelInstallation) {
        installations[record.id] = record
        installedIds.insert(record.id)
        corruptedIds.remove(record.id)
        persist()
    }

    // MARK: Activation

    /// Make a model the active engine. Loading happens through the existing
    /// `.modelChanged` path so there is exactly one loader.
    func activate(_ id: String) {
        guard installedIds.contains(id) else { return }
        guard id != settings.modelId else { return }
        settings.modelId = id
        NotificationCenter.default.post(name: .modelChanged, object: nil)
        noteUsed(id)
        objectWillChange.send()
    }

    /// Record that a model was used for a transcription (§36, §41).
    func noteUsed(_ id: String) {
        guard var record = installations[id] else { return }
        record.lastUsedAt = Date()
        record.usageCount += 1
        installations[id] = record
        persist()
    }

    // MARK: Favorites (§35)

    func isFavorite(_ id: String) -> Bool { installations[id]?.isFavorite ?? false }

    func toggleFavorite(_ id: String) {
        guard var record = installations[id] else { return }
        record.isFavorite.toggle()
        installations[id] = record
        persist()
    }

    var favorites: [ModelDescriptor] {
        installations.values.filter(\.isFavorite).map { descriptor(for: $0.id) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Recently used, most recent first, excluding the active model (§36 — this
    /// must not compete with the active-model section).
    func recentlyUsed(limit: Int = 3) -> [(ModelDescriptor, Date)] {
        installations.values
            .filter { $0.id != activeId }
            .compactMap { r in r.lastUsedAt.map { (descriptor(for: r.id), $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Revision pinning (§32)

    func pin(_ id: String, revision: String?) {
        guard var record = installations[id] else { return }
        record.pinnedRevision = revision?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        installations[id] = record
        persist()
    }

    func pinnedRevision(_ id: String) -> String? { installations[id]?.pinnedRevision }

    // MARK: Verification & repair (§50)

    /// Re-check a model's files against what its runtime needs.
    @discardableResult
    func verify(_ id: String) async -> Bool {
        guard let record = installations[id] else { return false }
        let path = record.installedPath
        let engine = record.engine
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            switch engine {
            case .whisperKit: return ModelDisk.hasCoreMLWeights(url)
            case .llamaCPP:   return ModelDisk.directoryBytes(url) > 0
            }
        }.value
        var updated = record
        updated.verification = ok ? .verified : .failed
        installations[id] = updated
        if ok { installedIds.insert(id); corruptedIds.remove(id) }
        else { installedIds.remove(id); corruptedIds.insert(id) }
        persist()
        return ok
    }

    // MARK: Removal (§51, §52)

    enum RemoveRefusal: LocalizedError {
        case isActive(String)
        case busy

        var errorDescription: String? {
            switch self {
            case .isActive(let name):
                return "\(name) is currently active. Choose another model before removing it."
            case .busy:
                return "A download or model load is running — try again in a moment."
            }
        }
    }

    /// Bytes a removal would free, for the confirmation dialog.
    func removableBytes(_ id: String) -> Int64 { installations[id]?.sizeBytes ?? 0 }

    /// Never allow the running engine's files to disappear underneath it.
    func canRemove(_ id: String) -> Result<Void, RemoveRefusal> {
        if id == activeId { return .failure(.isActive(descriptor(for: id).displayName)) }
        if ModelDownloadQueue.shared.job(for: id) != nil { return .failure(.busy) }
        return .success(())
    }

    @discardableResult
    func remove(_ id: String) async -> Int64 {
        guard case .success = canRemove(id) else { return 0 }
        ModelDownloadQueue.shared.markRemoving(id)
        defer { ModelDownloadQueue.shared.clearRemoving(id) }

        let record = installations[id]
        let freed: Int64
        if let llama = LlamaModelOption.find(id: id) {
            let bytes = GGUFDownloader.onDiskBytes(llama)
            GGUFDownloader.remove(llama)
            freed = bytes
        } else if let custom = CustomGGUFModel.parse(id) {
            let bytes = GGUFDownloader.customBytes(custom)
            GGUFDownloader.removeCustom(custom)
            freed = bytes
        } else if let path = record?.installedPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            freed = await Task.detached(priority: .utility) { ModelDisk.removeFolder(url) }.value
        } else if let folder = descriptor(for: id).folderName,
                  let url = ModelDisk.findFolder(named: folder) {
            freed = await Task.detached(priority: .utility) { ModelDisk.removeFolder(url) }.value
        } else {
            freed = 0
        }
        // Benchmarks survive removal (§52) — only the files go.
        installations.removeValue(forKey: id)
        installedIds.remove(id)
        corruptedIds.remove(id)
        persist()
        return freed
    }

    // MARK: Storage report (§23)

    func storageReport() async -> ModelStorageReport {
        let root = ModelStorageLocation.currentRoot
        let records = installations
        let active = activeId
        return await Task.detached(priority: .utility) { () -> ModelStorageReport in
            var report = ModelStorageReport()
            report.root = root
            for (id, record) in records {
                let url = URL(fileURLWithPath: record.installedPath, isDirectory: true)
                let bytes = record.installedPath.isEmpty ? record.sizeBytes : ModelDisk.directoryBytes(url)
                guard bytes > 0 else { continue }
                report.items.append(ModelStorageReport.Item(
                    id: id, name: record.displayName, bytes: bytes, path: url,
                    isActive: id == active, lastUsed: record.lastUsedAt
                ))
            }
            report.items.sort { $0.bytes > $1.bytes }
            report.incompleteBytes = ModelDisk.incompleteBytes(root: root)
            let values = try? root.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
            ])
            report.freeBytes = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
            report.volumeName = values?.volumeName ?? ""
            return report
        }.value
    }

    /// Discard interrupted downloads and staging data. Returns bytes freed.
    func clearIncompleteDownloads() async -> Int64 {
        guard !AppState.shared.isDownloading else { return 0 }
        let root = ModelStorageLocation.currentRoot
        let freed = await Task.detached(priority: .utility) {
            ModelDisk.clearIncomplete(root: root)
        }.value
        await scan()
        return freed
    }

    // MARK: Persistence

    private func persist() {
        let list = Array(installations.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([ModelInstallation].self, from: data) else { return }
        installations = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
