import Foundation
import Network

// MARK: - Structured repository metadata
//
// §15/§28: prefer the Hub's structured fields over scraping README prose. The
// app's own model abstraction sits above these types — no view ever parses a
// Hugging Face response.

/// One file in a repository, as the Hub reports it.
struct HFFileEntry: Codable, Identifiable, Hashable {
    let path: String
    let sizeBytes: Int64
    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String? {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
    var sizeLabel: String {
        sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "—"
    }
    var isWeightFile: Bool {
        let n = fileName.lowercased()
        return n.hasSuffix(".gguf") || n.hasSuffix(".safetensors") || n.hasSuffix(".bin")
            || n.hasSuffix(".mlmodel") || n.hasSuffix(".espresso.weights") || path.contains(".mlmodelc/")
    }
}

/// A logical, installable build inside a repository (§17). A repository with
/// four quantizations is four variants, not four hundred files.
struct ModelVariant: Identifiable, Hashable {
    /// The id this becomes as an installed model.
    let id: String
    /// "openai_whisper-base", "Q8_0", "INT4"…
    let label: String
    let format: ModelFileFormat
    let quantization: String?
    let sizeBytes: Int64
    let files: [HFFileEntry]
    /// Whether a shipped runtime can actually load it.
    let isSupported: Bool
    let unsupportedReason: String?

    var sizeLabel: String {
        sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "—"
    }

    /// Sharded weights presented as one group (§16) rather than N rows.
    var weightGroup: (count: Int, bytes: Int64)? {
        let weights = files.filter(\.isWeightFile)
        guard weights.count > 1 else { return nil }
        return (weights.count, weights.reduce(0) { $0 + $1.sizeBytes })
    }
}

/// Everything the app keeps about one Hugging Face repository.
struct HFRepoMetadata: Codable, Hashable {
    var repoId: String
    var author: String
    /// Commit the metadata describes — the anchor for update detection (§31).
    var sha: String?
    var pipelineTag: String?
    var libraryName: String?
    var license: String?
    var languages: [String]
    var tags: [String]
    var downloads: Int
    var likes: Int
    var lastModified: Date?
    var isGated: Bool
    var files: [HFFileEntry]
    var cardSummary: String?
    var fetchedAt: Date

    var repositoryURL: URL {
        URL(string: "https://huggingface.co/\(repoId)") ?? URL(string: "https://huggingface.co")!
    }

    var lastModifiedLabel: String {
        guard let lastModified else { return "—" }
        return DateFormatter.localizedString(from: lastModified, dateStyle: .medium, timeStyle: .none)
    }

    var shortSha: String? { sha.map { String($0.prefix(7)) } }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    /// Age of this cache entry, for "Updated 12 minutes ago".
    var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }

    // MARK: Variant derivation

    /// Core ML model folders: a folder counts only when all three compiled
    /// bundles are present, which is exactly what WhisperKit needs to load.
    var coreMLVariants: [ModelVariant] {
        var byFolder: [String: [HFFileEntry]] = [:]
        for file in files {
            guard let top = file.path.split(separator: "/").first.map(String.init),
                  !top.hasPrefix(".") else { continue }
            byFolder[top, default: []].append(file)
        }
        return byFolder.compactMap { folder, entries -> ModelVariant? in
            let bundles = Set(entries.compactMap { entry -> String? in
                let parts = entry.path.split(separator: "/")
                guard parts.count >= 2 else { return nil }
                return String(parts[1])
            })
            let complete = ModelDisk.coreMLBundles.allSatisfy { bundles.contains($0) }
            guard complete else { return nil }
            return ModelVariant(
                id: "\(repoId):\(folder)",
                label: folder,
                format: .coreML,
                quantization: Self.quantizationHint(folder),
                sizeBytes: entries.reduce(0) { $0 + $1.sizeBytes },
                files: entries.sorted { $0.path < $1.path },
                isSupported: true,
                unsupportedReason: nil
            )
        }
        .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// GGUF builds this app can run: a decoder file paired with the matching
    /// `mmproj-` audio projector. A GGUF without a projector is a text model,
    /// not something the ASR backend can load — so it is reported as
    /// unsupported with a reason rather than offered and then failing.
    var ggufVariants: [ModelVariant] {
        let ggufs = files.filter { $0.fileName.lowercased().hasSuffix(".gguf") }
        guard !ggufs.isEmpty else { return [] }
        let projectors = ggufs.filter { $0.fileName.lowercased().hasPrefix("mmproj") }
        let weights = ggufs.filter { !$0.fileName.lowercased().hasPrefix("mmproj") }

        return weights.map { weight -> ModelVariant in
            let quant = Self.quantizationHint(weight.fileName) ?? "GGUF"
            let projector = projectors.first {
                Self.quantizationHint($0.fileName)?.lowercased() == quant.lowercased()
            } ?? projectors.first
            let supported = projector != nil
            return ModelVariant(
                // Self-describing id: the downloader and the loader both need
                // the exact file pair, and neither should have to consult a
                // record that doesn't exist yet at install time.
                id: CustomGGUFModel.makeId(repoId: repoId, weights: weight.fileName,
                                           mmproj: projector?.fileName ?? ""),
                label: quant,
                format: .gguf,
                quantization: quant,
                sizeBytes: weight.sizeBytes + (projector?.sizeBytes ?? 0),
                files: [weight] + (projector.map { [$0] } ?? []),
                isSupported: supported,
                unsupportedReason: supported ? nil
                    : "This GGUF has no matching mmproj audio projector, which the speech backend needs to read audio."
            )
        }
        .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Every installable build, best-supported first.
    var variants: [ModelVariant] {
        let all = coreMLVariants + ggufVariants
        return all.sorted {
            if $0.isSupported != $1.isSupported { return $0.isSupported }
            return $0.sizeBytes < $1.sizeBytes
        }
    }

    /// What the repository ships, even when nothing is installable — so §69 can
    /// explain *why* rather than hiding the model.
    var detectedFormat: ModelFileFormat {
        if files.contains(where: { $0.path.contains(".mlmodelc/") }) { return .coreML }
        if files.contains(where: { $0.fileName.lowercased().hasSuffix(".gguf") }) { return .gguf }
        if files.contains(where: { $0.fileName.lowercased().hasSuffix(".safetensors") }) { return .safetensors }
        if files.contains(where: { $0.fileName.lowercased().hasSuffix(".onnx") }) { return .onnx }
        return .other
    }

    /// "Q8_0", "INT8", "954MB" pulled from a file or folder name.
    static func quantizationHint(_ name: String) -> String? {
        let patterns = [#"[Qq]\d(_[A-Za-z0-9]+)+"#, #"(?i)bf16|fp16|fp32|int8|int5|int4"#, #"_\d+MB"#]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                return String(name[range]).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            }
        }
        return nil
    }
}

// MARK: - Repository metadata

extension HFModelSearch {
    /// Full metadata for one repository (§77 stage 3).
    static func fetchMetadata(repoId: String, revision: String? = nil) async throws -> HFRepoMetadata {
        let ref = revision.flatMap { $0.isEmpty ? nil : $0 }
        let base = ref.map { "https://huggingface.co/api/models/\(repoId)/revision/\($0)" }
            ?? "https://huggingface.co/api/models/\(repoId)"
        guard var comps = URLComponents(string: base) else { throw URLError(.badURL) }
        comps.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = comps.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = Keychain.getToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MetadataError.gated(repoId)
            }
            if http.statusCode == 404 { throw MetadataError.notFound(repoId) }
            throw URLError(.badServerResponse)
        }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let tags = (dict["tags"] as? [String]) ?? []
        let lower = tags.map { $0.lowercased() }
        let cardData = dict["cardData"] as? [String: Any]

        // Languages come from the card's structured `language` field, with the
        // `language:xx` tags as a fallback — never from README prose.
        var languages: [String] = []
        if let list = cardData?["language"] as? [String] { languages = list }
        else if let single = cardData?["language"] as? String { languages = [single] }
        if languages.isEmpty {
            languages = lower.filter { $0.hasPrefix("language:") }
                .map { String($0.dropFirst("language:".count)) }
        }
        languages = languages.map { $0.lowercased() }

        let license = (cardData?["license"] as? String)
            ?? lower.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst("license:".count)) }

        let files: [HFFileEntry] = ((dict["siblings"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let name = s["rfilename"] as? String, !name.hasPrefix(".") else { return nil }
            return HFFileEntry(path: name, sizeBytes: Int64((s["size"] as? Int) ?? 0))
        }

        return HFRepoMetadata(
            repoId: repoId,
            author: (dict["author"] as? String)
                ?? repoId.split(separator: "/").first.map(String.init) ?? repoId,
            sha: dict["sha"] as? String,
            pipelineTag: dict["pipeline_tag"] as? String,
            libraryName: dict["library_name"] as? String,
            license: license,
            languages: languages,
            tags: tags.filter { !$0.contains(":") },
            downloads: (dict["downloads"] as? Int) ?? 0,
            likes: (dict["likes"] as? Int) ?? 0,
            lastModified: HFHub.parseDate(dict["lastModified"] as? String),
            isGated: (dict["gated"] as? String).map { $0 != "false" && !$0.isEmpty }
                ?? (dict["gated"] as? Bool ?? false),
            files: files.sorted { $0.path < $1.path },
            cardSummary: nil,
            fetchedAt: Date()
        )
    }

    enum MetadataError: LocalizedError {
        case gated(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .gated(let repo):
                return "\(repo) requires access approval on Hugging Face. Add a token in Settings once you've been granted access."
            case .notFound(let repo):
                return "There's no Hugging Face repository called \(repo)."
            }
        }
    }

    /// Accepts a bare repo id or any Hugging Face URL the user pastes (§63).
    static func parseRepoReference(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let host = url.host, host.contains("huggingface.co") {
            let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            // /<org>/<model>[/tree/<rev>…]
            guard parts.count >= 2 else { return nil }
            if parts[0] == "models" && parts.count >= 3 { return "\(parts[1])/\(parts[2])" }
            return "\(parts[0])/\(parts[1])"
        }
        // "org/model"
        let parts = text.split(separator: "/")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return text }
        return nil
    }
}

// MARK: - Cache

/// Normalized metadata cache with stale-while-revalidate semantics (§27, §78).
///
/// Keyed by `repositoryId@revision`. The UI renders cached data immediately —
/// including with no network at all — and a background refresh replaces it when
/// (and only when) one succeeds.
@MainActor
final class HFMetadataCache: ObservableObject {
    static let shared = HFMetadataCache()

    @Published private(set) var entries: [String: HFRepoMetadata] = [:]
    @Published private(set) var inFlight: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// Newest successful network response of any kind, for "Updated N ago".
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var isOnline = true

    /// Metadata older than this is refreshed in the background on next read.
    private let staleAfter: TimeInterval = 60 * 60 * 6
    private let monitor = NWPathMonitor()

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/hf-metadata.json")
    }

    private init() {
        load()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.behkha.notchwhisper.reachability"))
    }

    private func key(_ repoId: String, _ revision: String?) -> String {
        "\(repoId)@\(revision ?? "main")"
    }

    /// Cached metadata, if any. Never triggers a fetch — call `ensure` for that.
    func cached(_ repoId: String, revision: String? = nil) -> HFRepoMetadata? {
        entries[key(repoId, revision)]
    }

    func error(for repoId: String, revision: String? = nil) -> String? {
        errors[key(repoId, revision)]
    }

    func isLoading(_ repoId: String, revision: String? = nil) -> Bool {
        inFlight.contains(key(repoId, revision))
    }

    /// Return what's cached and refresh in the background when stale. With no
    /// network the cached copy is simply kept — the page stays useful (§26).
    @discardableResult
    func ensure(_ repoId: String, revision: String? = nil, force: Bool = false) -> HFRepoMetadata? {
        let k = key(repoId, revision)
        let existing = entries[k]
        let stale = existing.map { $0.age > staleAfter } ?? true
        if (force || stale), !inFlight.contains(k), isOnline {
            inFlight.insert(k)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let fresh = try await HFModelSearch.fetchMetadata(repoId: repoId, revision: revision)
                    self.entries[k] = fresh
                    self.errors[k] = nil
                    self.lastSuccessfulRefresh = Date()
                    self.save()
                } catch {
                    // A failed refresh must never destroy good cached data.
                    self.errors[k] = error.localizedDescription
                }
                self.inFlight.remove(k)
            }
        }
        return existing
    }

    /// Await fresh metadata (used by the paste-a-URL inspector, where the user
    /// is explicitly waiting for a result).
    func fetch(_ repoId: String, revision: String? = nil) async throws -> HFRepoMetadata {
        let k = key(repoId, revision)
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        do {
            let fresh = try await HFModelSearch.fetchMetadata(repoId: repoId, revision: revision)
            entries[k] = fresh
            errors[k] = nil
            lastSuccessfulRefresh = Date()
            save()
            return fresh
        } catch {
            errors[k] = error.localizedDescription
            throw error
        }
    }

    /// Is a newer revision published than the one that was installed? (§31)
    func updateAvailable(for install: ModelInstallation) -> (installed: String, latest: String)? {
        // A pinned model deliberately stays where it is (§32).
        guard install.pinnedRevision == nil else { return nil }
        guard let installed = install.commitSha,
              let latest = cached(install.repositoryId)?.sha,
              installed != latest else { return nil }
        return (String(installed.prefix(7)), String(latest.prefix(7)))
    }

    /// "Updated 12 minutes ago" / "Showing cached data from yesterday".
    var freshnessLabel: String? {
        guard let date = lastSuccessfulRefresh else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Updated " + formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Persistence

    private func save() {
        // Bound the cache so it can't grow without limit as the user browses.
        var toSave = entries
        if toSave.count > 120 {
            let keep = toSave.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(120)
            toSave = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            entries = toSave
        }
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let map = try? JSONDecoder().decode([String: HFRepoMetadata].self, from: data) else { return }
        entries = map
        lastSuccessfulRefresh = map.values.map(\.fetchedAt).max()
    }
}
