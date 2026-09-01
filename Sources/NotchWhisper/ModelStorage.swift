import Foundation
import AppKit

// MARK: - Storage location
//
// Every model path in the app resolves through here so the storage directory
// can be relocated (Models → Storage → Change Location…) without any component
// holding a stale hardcoded path.

/// The on-disk root for all downloaded models.
///
/// `Transcriber.modelDir` and `GGUFDownloader.root()` both read this, so a
/// relocation moves every engine at once. The location is only ever changed by
/// `migrate(to:)`, which copies, verifies, then removes — never by editing the
/// stored path alone.
@MainActor
final class ModelStorageLocation: ObservableObject {
    static let shared = ModelStorageLocation()

    nonisolated static let key = "modelStorageDirectory"

    /// `~/Library/Application Support/NotchWhisper/Models`
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/Models", isDirectory: true)
    }

    /// Resolved synchronously from UserDefaults — safe from any isolation
    /// context (the downloaders and the transcriber both need it off-main).
    nonisolated static var currentRoot: URL {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return defaultRoot
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Published mirror so SwiftUI repaints after a migration.
    @Published private(set) var root: URL = ModelStorageLocation.currentRoot
    @Published private(set) var isMigrating = false
    @Published private(set) var migrationPhase = ""

    var isDefaultLocation: Bool { root.standardizedFileURL == Self.defaultRoot.standardizedFileURL }

    private init() {}

    enum MigrationError: LocalizedError {
        case busy
        case sameLocation
        case notWritable(String)
        case insufficientSpace(needed: Int64, free: Int64)
        case copyFailed(String)
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Finish the download or model load that's running, then move the models."
            case .sameLocation:
                return "That's already where your models are stored."
            case .notWritable(let path):
                return "NotchWhisper can't write to \(path). Pick a folder you own."
            case .insufficientSpace(let needed, let free):
                return "That volume has \(Self.bytes(free)) free — the models need \(Self.bytes(needed))."
            case .copyFailed(let why):
                return "The move stopped partway: \(why). Your models were left where they were."
            case .verifyFailed:
                return "The copied files didn't match the originals, so nothing was deleted."
            }
        }

        private static func bytes(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        }
    }

    /// Move every model to `newRoot`: copy → verify byte totals → delete the
    /// originals → publish the new path. Interrupted at any point before the
    /// final step, the original location is still intact and still active.
    func migrate(to newRoot: URL) async throws {
        guard !isMigrating else { throw MigrationError.busy }
        guard !AppState.shared.isDownloading, !AppState.shared.isLoadingModel else {
            throw MigrationError.busy
        }
        let destination = newRoot.appendingPathComponent("NotchWhisperModels", isDirectory: true)
        let source = root
        guard destination.standardizedFileURL != source.standardizedFileURL else {
            throw MigrationError.sameLocation
        }

        let fm = FileManager.default
        guard fm.isWritableFile(atPath: newRoot.path) else {
            throw MigrationError.notWritable(newRoot.path)
        }

        isMigrating = true
        migrationPhase = "Measuring…"
        defer { isMigrating = false; migrationPhase = "" }

        let needed = await Task.detached(priority: .userInitiated) {
            ModelDisk.directoryBytes(source)
        }.value
        let capacity = (try? newRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let free: Int64 = capacity.map { Int64($0) } ?? 0
        if free > 0, needed > 0, free < needed + 200_000_000 {
            throw MigrationError.insufficientSpace(needed: needed, free: free)
        }

        migrationPhase = "Copying models…"
        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: destination)
                } else {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                }
            }.value
        } catch {
            try? fm.removeItem(at: destination)
            throw MigrationError.copyFailed(error.localizedDescription)
        }

        migrationPhase = "Verifying…"
        let copied = await Task.detached(priority: .userInitiated) {
            ModelDisk.directoryBytes(destination)
        }.value
        guard copied >= needed else {
            try? fm.removeItem(at: destination)
            throw MigrationError.verifyFailed
        }

        // Only now does the app start reading from the new location.
        UserDefaults.standard.set(destination.path, forKey: Self.key)
        root = destination

        migrationPhase = "Cleaning up…"
        try? fm.removeItem(at: source)
    }

    /// Put models back in Application Support (a migration in the other
    /// direction — same safety guarantees).
    func resetToDefault() async throws {
        try await migrate(to: Self.defaultRoot.deletingLastPathComponent())
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}

// MARK: - Disk truth
//
// One place that answers "what is actually on disk" for both engines. The
// registry, the transcriber and the storage view all read from here so
// "installed" can never mean two different things in two places.

enum ModelDisk {

    /// `<root>/models/argmaxinc/whisperkit-coreml` — where WhisperKit lands the
    /// built-in catalog.
    nonisolated static func whisperCatalogRoot(_ root: URL = ModelStorageLocation.currentRoot) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// `<root>/models/<repoId>` — where a custom Hugging Face repo lands.
    nonisolated static func customRepoRoot(_ repoId: String,
                                           root: URL = ModelStorageLocation.currentRoot) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
    }

    /// `<root>/Imported` — models the user brought in from disk.
    nonisolated static func importedRoot(_ root: URL = ModelStorageLocation.currentRoot) -> URL {
        root.appendingPathComponent("Imported", isDirectory: true)
    }

    // MARK: Whisper (Core ML)

    /// The three compiled bundles every WhisperKit model needs.
    static let coreMLBundles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    /// Whether a folder holds *complete* Core ML weights.
    ///
    /// Directory names appear as soon as a bundle's small metadata files land —
    /// long before the weights — so a name-only check reports an in-flight
    /// download as installed. Completeness therefore requires each bundle to
    /// carry real weight data (a `weights/` payload, or ≥200 KB of bundle bytes
    /// for older ML-program builds that inline weights in `coremldata.bin`).
    nonisolated static func hasCoreMLWeights(_ folder: URL) -> Bool {
        for name in coreMLBundles {
            let bundle = folder.appendingPathComponent(name, isDirectory: true)
            let weights = bundle.appendingPathComponent("weights", isDirectory: true)
            guard hasNonEmptyFile(weights) || directoryBytes(bundle) >= 200 * 1024 else { return false }
        }
        return true
    }

    /// Locate a named model folder anywhere under the model root, preferring
    /// one with complete weights (WhisperKit nests by org/repo).
    nonisolated static func findFolder(named folder: String,
                                       root: URL = ModelStorageLocation.currentRoot) -> URL? {
        let canonical = whisperCatalogRoot(root).appendingPathComponent(folder, isDirectory: true)
        if hasCoreMLWeights(canonical) { return canonical }
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        var fallback: URL?
        for case let url as URL in en where url.lastPathComponent == folder {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if hasCoreMLWeights(url) { return url }
            fallback = fallback ?? url
        }
        return fallback
    }

    /// Complete Core ML model folders present on disk (built-in catalog only).
    nonisolated static func installedCatalogFolders(root: URL = ModelStorageLocation.currentRoot) -> [String] {
        let known = Set(WhisperModelOption.all.map(\.folderName))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: whisperCatalogRoot(root), includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent != ".cache" }
            .filter { known.contains($0.lastPathComponent) }
            .filter { hasCoreMLWeights($0) }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Folders that exist but are missing weights — an interrupted download.
    nonisolated static func partialCatalogFolders(root: URL = ModelStorageLocation.currentRoot) -> [String] {
        let known = Set(WhisperModelOption.all.map(\.folderName))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: whisperCatalogRoot(root), includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent != ".cache" }
            .filter { known.contains($0.lastPathComponent) }
            .filter { !hasCoreMLWeights($0) }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: Byte accounting

    /// Sum of regular-file bytes under `url` (0 when it doesn't exist).
    nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            guard let v = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func hasNonEmptyFile(_ dir: URL) -> Bool {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return false }
        for case let url as URL in en {
            if let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true, (v.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    // MARK: Removal

    /// Delete a Core ML model folder. Returns the bytes freed.
    @discardableResult
    nonisolated static func removeFolder(_ url: URL) -> Int64 {
        let bytes = directoryBytes(url)
        try? FileManager.default.removeItem(at: url)
        return bytes
    }

    /// Bytes held by WhisperKit's download staging area and any orphaned
    /// `.incomplete` files — safe to discard when no download is running.
    nonisolated static func incompleteBytes(root: URL = ModelStorageLocation.currentRoot) -> Int64 {
        var total: Int64 = 0
        for url in incompleteURLs(root: root) { total += directoryBytes(url) }
        return total
    }

    nonisolated static func incompleteURLs(root: URL = ModelStorageLocation.currentRoot) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        // Partial catalog folders.
        for folder in partialCatalogFolders(root: root) {
            found.append(whisperCatalogRoot(root).appendingPathComponent(folder, isDirectory: true))
        }
        // WhisperKit's per-file resume staging + orphaned .incomplete files.
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in en {
                if url.lastPathComponent.hasSuffix(".incomplete") { found.append(url) }
                if url.lastPathComponent == "download",
                   url.deletingLastPathComponent().lastPathComponent == "huggingface" {
                    found.append(url)
                    en.skipDescendants()
                }
            }
        }
        return found
    }

    /// Remove interrupted downloads and staging data. Returns bytes freed.
    @discardableResult
    nonisolated static func clearIncomplete(root: URL = ModelStorageLocation.currentRoot) -> Int64 {
        var freed: Int64 = 0
        for url in incompleteURLs(root: root) { freed += removeFolder(url) }
        return freed
    }
}

// MARK: - Storage report

/// A snapshot of what the models are costing on disk. Computed off the main
/// thread; the view holds the result.
struct ModelStorageReport: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String            // model id
        let name: String
        let bytes: Int64
        let path: URL
        let isActive: Bool
        let lastUsed: Date?
    }

    var items: [Item] = []
    var incompleteBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var volumeName: String = ""
    var root: URL = ModelStorageLocation.currentRoot

    var usedBytes: Int64 { items.reduce(0) { $0 + $1.bytes } + incompleteBytes }

    /// Models not used in the last 30 days and not currently active.
    var unusedItems: [Item] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return items.filter { !$0.isActive && ($0.lastUsed ?? .distantPast) < cutoff }
    }

    static func label(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
