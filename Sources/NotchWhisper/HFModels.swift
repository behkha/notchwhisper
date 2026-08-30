import Foundation

/// Live search over Hugging Face's public model API so ANY Whisper/CoreML
/// speech model on the Hub can be found and used — not just the built-in
/// catalog of argmaxinc/whisperkit-coreml.
///
/// Only models USEFUL for this app (voice-to-text) are listed:
///   · pipeline_tag = automatic-speech-recognition (server-side filter)
///   · tagged `coreml` (server-side filter) — WhisperKit can only load
///     CoreML packages, so anything else would be dead weight.
/// Results are ranked by downloads (most-used first).
///
/// Endpoints (same public API the app's downloads already use — no deps):
///   GET https://huggingface.co/api/models?search=<q>&pipeline_tag=…&filter=coreml&sort=downloads&direction=-1&limit=N
///   GET https://huggingface.co/api/models/<repoId>?blobs=true   → per-file sizes
enum HFModelSearch {

    struct Repo: Identifiable, Hashable {
        let repoId: String        // e.g. "argmaxinc/whisperkit-coreml"
        let downloads: Int
        let likes: Int
        let lastModified: String  // human-formatted date
        let pipelineTag: String?
        let license: String?      // from tags, e.g. "mit"
        let library: String?      // e.g. "whisperkit"
        let isGated: Bool         // needs a HF token / access request
        let isCoreML: Bool
        let isWhisper: Bool
        var id: String { repoId }
    }

    /// A downloadable model folder inside a repo, with its EXACT size and a
    /// CoreML-weights check (metadata straight from the HF API).
    struct FolderInfo: Identifiable, Hashable {
        let name: String          // top-level folder, e.g. "openai_whisper-base"
        let sizeBytes: Int64      // exact sum of all files in the folder
        let hasWeights: Bool      // contains the Audio/Text/Mel CoreML models
        var id: String { name }

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static func humanDate(_ raw: String) -> String {
        guard !raw.isEmpty,
              let d = iso8601.date(from: raw) else { return raw }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none)
    }

    /// Search HF for speech-recognition CoreML models matching `query`,
    /// most-downloaded first. Server-side filters guarantee every result is
    /// usable for voice-to-text in this app.
    static func search(_ query: String, limit: Int = 30) async throws -> [Repo] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        let items: [URLQueryItem] = [
            URLQueryItem(name: "search", value: query),
            // Only automatic-speech-recognition models, CoreML-packaged:
            // anything else cannot be loaded by WhisperKit.
            URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition"),
            URLQueryItem(name: "filter", value: "coreml"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let repoId = dict["id"] as? String else { return nil }
            let tags = (dict["tags"] as? [String]) ?? []
            let lower = tags.map { $0.lowercased() }
            return Repo(
                repoId: repoId,
                downloads: (dict["downloads"] as? Int) ?? 0,
                likes: (dict["likes"] as? Int) ?? 0,
                lastModified: humanDate((dict["lastModified"] as? String) ?? ""),
                pipelineTag: dict["pipeline_tag"] as? String,
                license: lower.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst("license:".count)) },
                library: dict["library_name"] as? String,
                isGated: (dict["gated"] as? String).map { $0 != "false" && $0 != "" }
                          ?? (dict["gated"] as? Bool ?? false),
                isCoreML: lower.contains("coreml") || repoId.lowercased().contains("coreml"),
                isWhisper: repoId.lowercased().contains("whisper") || lower.contains(where: { $0.contains("whisper") })
            )
        }
    }

    /// The downloadable model folders inside a repo with EXACT sizes and a
    /// weights check. Parses `siblings` (with `blobs=true` sizes) of
    /// GET /api/models/<repoId>.
    static func listModelFolders(repoId: String) async throws -> [FolderInfo] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)?blobs=true") else { return [] }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = dict["siblings"] as? [[String: Any]] else { return [] }

        var sizeByFolder: [String: Int64] = [:]
        var hasEncoder = Set<String>()
        var hasDecoder = Set<String>()
        var hasMel = Set<String>()
        for s in siblings {
            guard let name = s["rfilename"] as? String, name.contains("/") else { continue }
            let parts = name.split(separator: "/")
            let top = String(parts[0])
            guard !top.hasPrefix(".") else { continue }        // skip .cache etc.
            sizeByFolder[top, default: 0] += Int64((s["size"] as? Int) ?? 0)
            if parts.count >= 2 {
                let sub = String(parts[1])
                if sub == "AudioEncoder.mlmodelc" { hasEncoder.insert(top) }
                if sub == "TextDecoder.mlmodelc"  { hasDecoder.insert(top) }
                if sub == "MelSpectrogram.mlmodelc" { hasMel.insert(top) }
            }
        }
        var infos: [FolderInfo] = []
        for (folder, size) in sizeByFolder {
            let weights = hasEncoder.contains(folder) && hasDecoder.contains(folder) && hasMel.contains(folder)
            infos.append(FolderInfo(name: folder, sizeBytes: size, hasWeights: weights))
        }
        return infos.sorted { $0.name < $1.name }
    }
}
