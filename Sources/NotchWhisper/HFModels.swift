import Foundation

/// Per-repository Hugging Face metadata: the file listing, the full record for
/// one repo, and the pasted-reference parser.
///
/// Searching the Hub lives in `HFHub` — this type is only about a repository
/// the app already knows the id of.
///
/// Endpoints (the same public API the downloads use — no dependencies):
///   GET https://huggingface.co/api/models/<repoId>?blobs=true   → per-file sizes
enum HFModelSearch {

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
