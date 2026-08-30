import Foundation
import SwiftUI

/// Real, per-folder download sizes for the built-in `argmaxinc/whisperkit-coreml`
/// catalog, fetched once from the Hugging Face API and cached on disk.
///
/// The hardcoded `WhisperModelOption.size` strings are rough guesses (they were
/// off by 2–3× for several tiers); this replaces them with the exact byte count
/// HF reports for the folder, so both the UI size AND the download progress bar
/// are accurate (req 5).
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    /// folderName → exact size in bytes (from HF `siblings` blob sizes).
    @Published private(set) var sizeByFolder: [String: Int64] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let repoId = "argmaxinc/whisperkit-coreml"
    private let cacheURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/model-sizes.json")
    }()
    private let ttl: TimeInterval = 60 * 60 * 24 * 7   // 1 week

    private struct Cache: Codable {
        var fetchedAt: Date
        var sizes: [String: Int64]
    }

    private init() {
        loadCache()
    }

    /// Exact size for a catalog folder, or nil until the HF fetch lands.
    func sizeBytes(forFolder folder: String) -> Int64? {
        sizeByFolder[folder]
    }

    /// Human size string for a model, preferring the real HF number and
    /// falling back to the catalog's approximate label.
    func sizeLabel(for model: WhisperModelOption) -> String {
        if let bytes = sizeByFolder[model.folderName], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return model.size
    }

    /// Best-known total bytes for a download (real HF size, else parsed label).
    func downloadTotalBytes(for model: WhisperModelOption) -> Int64 {
        if let bytes = sizeByFolder[model.folderName], bytes > 0 { return bytes }
        return Transcriber.parseSizeLabel(model.size)
    }

    // MARK: - Fetch

    /// Refresh from HF if the cache is stale (or `force`). Safe to call from
    /// `onAppear`; it de-dupes concurrent calls.
    func refreshIfNeeded(force: Bool = false) {
        guard !isRefreshing else { return }
        if !force, let age = cacheAge, age < ttl, !sizeByFolder.isEmpty { return }
        isRefreshing = true
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let folders = try await HFModelSearch.listModelFolders(repoId: repoId)
                var map: [String: Int64] = [:]
                for f in folders where f.sizeBytes > 0 { map[f.name] = f.sizeBytes }
                await MainActor.run {
                    if !map.isEmpty { self.sizeByFolder = map; self.saveCache(map) }
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.isRefreshing = false
                }
            }
        }
    }

    private var cacheAge: TimeInterval? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        return Date().timeIntervalSince(cache.fetchedAt)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        sizeByFolder = cache.sizes
    }

    private func saveCache(_ sizes: [String: Int64]) {
        let cache = Cache(fetchedAt: Date(), sizes: sizes)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL)
    }
}
