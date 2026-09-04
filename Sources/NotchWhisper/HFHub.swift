import Foundation

// MARK: - Hugging Face Hub search
//
// The Hub is the app's model catalogue, so browsing it has to be a first-class
// surface rather than a URL box. This file is the whole network side of that:
// one typed request against `GET /api/models`, and one normalized result type
// carrying *everything* the API is willing to tell us about a repository.
//
// Design notes:
//   · `expand[]` is used instead of `full=true` so the exact field set is
//     explicit and reviewable. Every field below is one the Hub really returns.
//   · Nothing is filtered away for being unsupported. A model this app cannot
//     run is still shown, with the reason attached (§69) — hiding it just makes
//     the search look broken.
//   · Results are paginated with the Hub's cursor `Link: …; rel="next"` header,
//     which is the only reliable way to walk past the first page.

// MARK: Evaluation results

/// One published benchmark number from a repository's `.eval_results` files.
/// These are the model's own claims, never this app's measurements — they are
/// always rendered with `published` provenance (§13).
struct HFEvalResult: Hashable, Identifiable {
    let datasetId: String
    /// "mean_wer", "rtfx", "ami_wer", "Hindi_WER"…
    let taskId: String
    let value: Double
    let date: String?
    let sourceName: String?
    let verified: Bool

    var id: String { "\(datasetId)#\(taskId)" }

    /// Lower is better for error rates; higher is better for speed factors.
    var isErrorRate: Bool { taskId.lowercased().contains("wer") || taskId.lowercased().contains("cer") }
    var isSpeedFactor: Bool { taskId.lowercased() == "rtfx" }

    var metricLabel: String {
        switch taskId.lowercased() {
        case "mean_wer": return "Mean WER"
        case "rtfx":     return "Real-time factor"
        default:
            // "ami_wer" → "AMI WER", "Hindi_WER" → "Hindi WER"
            let parts = taskId.split(separator: "_").map(String.init)
            return parts.map { $0.count <= 3 ? $0.uppercased() : $0.capitalized }
                .joined(separator: " ")
        }
    }

    var valueLabel: String {
        if isErrorRate { return String(format: "%.2f%%", value) }
        if isSpeedFactor { return String(format: "%.0f× real time", value) }
        return String(format: "%.2f", value)
    }

    var datasetLabel: String {
        datasetId.split(separator: "/").last.map(String.init) ?? datasetId
    }
}

/// A serverless inference provider the Hub has wired up for this repository.
/// Listed for completeness — this app never sends audio to any of them.
struct HFInferenceProvider: Hashable, Identifiable {
    let provider: String
    let status: String
    let task: String?
    var id: String { provider }
    var isLive: Bool { status.lowercased() == "live" }
}

/// How this app can (or can't) run a repository.
enum HFInstallability: Hashable {
    case installable(ModelFileFormat)
    case unsupported(ModelFileFormat, reason: String)

    var format: ModelFileFormat {
        switch self {
        case .installable(let f):      return f
        case .unsupported(let f, _):   return f
        }
    }
    var canInstall: Bool {
        if case .installable = self { return true }
        return false
    }
    var reason: String? {
        if case .unsupported(_, let r) = self { return r }
        return nil
    }
}

// MARK: Result

/// One Hub repository, with every field the search API exposes.
struct HFHubModel: Identifiable, Hashable {
    let repoId: String
    let author: String
    /// The part after the slash — what a person calls the model.
    let name: String
    /// `cardData.pretty_name`, when the publisher set one.
    let prettyName: String?

    // Classification
    let pipelineTag: String?
    let libraryName: String?
    let license: String?
    /// Free-form tags with the `key:value` ones stripped out.
    let tags: [String]
    /// Every raw tag, including `license:mit` / `language:fr` / `region:us`.
    let rawTags: [String]
    let languages: [String]

    // Popularity
    let downloads30d: Int
    let downloadsAllTime: Int
    let likes: Int
    let trendingScore: Int

    // Provenance
    let createdAt: Date?
    let lastModified: Date?
    let sha: String?
    let isGated: Bool
    /// "auto" or "manual" when gated, nil otherwise.
    let gatedKind: String?
    let isPrivate: Bool

    // Weights
    /// Total parameters from `safetensors.total` or `gguf.total`.
    let parameterCount: Int64?
    /// e.g. ["F16": 808878080] — the precision breakdown of the safetensors.
    let precisions: [String: Int64]
    /// `gguf.totalFileSize` — the only download size the search API ever gives.
    let ggufBytes: Int64?
    /// File paths from `siblings` (names only; the list API omits sizes).
    let fileNames: [String]

    // Lineage
    let baseModels: [String]
    /// "finetune", "quantized", "adapter", "merge"…
    let baseModelRelation: String?

    // Published numbers
    let evals: [HFEvalResult]
    let inferenceProviders: [HFInferenceProvider]

    var id: String { repoId }

    var repositoryURL: URL {
        URL(string: "https://huggingface.co/\(repoId)") ?? URL(string: "https://huggingface.co")!
    }

    var displayName: String { prettyName ?? name }

    // MARK: Derived

    /// The weight format this repository actually ships, read from the file
    /// list first and the tags only as a fallback.
    var detectedFormat: ModelFileFormat {
        let lower = fileNames.map { $0.lowercased() }
        if lower.contains(where: { $0.contains(".mlmodelc/") }) { return .coreML }
        if lower.contains(where: { $0.hasSuffix(".gguf") }) { return .gguf }
        if lower.contains(where: { $0.hasSuffix(".safetensors") }) { return .safetensors }
        if lower.contains(where: { $0.hasSuffix(".onnx") }) { return .onnx }
        if !fileNames.isEmpty { return .other }
        // No file list (a trimmed response): fall back to the tags.
        let t = Set(rawTags.map { $0.lowercased() })
        if t.contains("coreml") { return .coreML }
        if t.contains("gguf") { return .gguf }
        if t.contains("safetensors") { return .safetensors }
        if t.contains("onnx") { return .onnx }
        return .other
    }

    /// Whether this app can install it, and if not, why not — in plain words.
    var installability: HFInstallability {
        let format = detectedFormat
        switch format {
        case .coreML:
            // WhisperKit loads compiled bundles; an uncompiled .mlpackage is a
            // Core ML repo it still cannot open.
            let compiled = fileNames.contains { $0.contains(".mlmodelc/") }
            return compiled
                ? .installable(.coreML)
                : .unsupported(.coreML, reason: "These Core ML weights aren't compiled (.mlmodelc), which WhisperKit needs.")
        case .gguf:
            // The GGUF speech backend needs the audio projector alongside the
            // decoder; a bare GGUF here is a text model.
            let hasProjector = fileNames.contains { $0.lowercased().hasPrefix("mmproj") || $0.lowercased().contains("/mmproj") }
            if fileNames.isEmpty { return .installable(.gguf) }
            return hasProjector
                ? .installable(.gguf)
                : .unsupported(.gguf, reason: "No mmproj audio projector in this repository, which the speech backend needs to read audio.")
        case .safetensors, .onnx, .other:
            let ct2 = fileNames.contains { $0.lowercased().hasSuffix("model.bin") }
                && rawTags.contains { $0.lowercased().contains("ctranslate2") }
            if ct2 {
                return .unsupported(.other, reason: "CTranslate2 weights (faster-whisper). NotchWhisper runs Core ML and GGUF models only.")
            }
            return .unsupported(format, reason: ModelRuntimeRegistry.unsupportedReason(for: format))
        }
    }

    var canInstall: Bool { installability.canInstall }

    /// Is this a speech model? The Hub's `pipeline_tag` is authoritative when
    /// present, but plenty of quantized repos omit it — the app's own
    /// `ggml-org/Qwen3-ASR-1.7B-GGUF` among them — so tags, the base model and
    /// the repository name are consulted as evidence.
    ///
    /// Only needed when a query runs without the task filter; a tagged search
    /// never has to guess.
    var looksLikeSpeech: Bool {
        if let tag = pipelineTag {
            return tag.hasPrefix("automatic-speech-recognition")
                || tag.hasPrefix("audio") || tag.hasPrefix("voice")
        }
        let haystack = (rawTags + baseModels + [repoId]).joined(separator: " ").lowercased()
        let markers = ["asr", "whisper", "speech", "audio", "parakeet", "wav2vec",
                       "moonshine", "canary", "voice", "stt", "transcri"]
        return markers.contains { haystack.contains($0) }
    }

    /// The best single accuracy claim, preferring the Open ASR Leaderboard.
    var headlineWER: HFEvalResult? {
        evals.first { $0.taskId.lowercased() == "mean_wer" }
            ?? evals.first { $0.isErrorRate }
    }
    var headlineSpeed: HFEvalResult? { evals.first { $0.isSpeedFactor } }

    /// "809M", "1.55B" — nil when the repository doesn't declare a count.
    var parameterLabel: String? {
        guard let n = parameterCount, n > 0 else { return nil }
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.0fM", d / 1e6) }
        return String(format: "%.0fK", d / 1e3)
    }

    /// Download size, only when the Hub actually published one.
    var sizeLabel: String? {
        guard let bytes = ggufBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var updatedLabel: String { HFHub.relative(lastModified) }
    var createdLabel: String { HFHub.relative(createdAt) }

    var shortSha: String? { sha.map { String($0.prefix(7)) } }

    /// Everything a text search should look at, lowercased once.
    var searchHaystack: String {
        ([repoId, author, name, prettyName ?? "", libraryName ?? "", license ?? "",
          pipelineTag ?? ""] + tags + languages).joined(separator: " ").lowercased()
    }
}

// MARK: - Query

/// The facets the browse sheet exposes. Everything here maps onto a real Hub
/// query parameter — no client-side pretending.
struct HFHubQuery: Equatable {
    /// Free text, matched against the repository name by the Hub.
    var text: String = ""
    /// `pipeline_tag`. Speech-to-text by default: this is a dictation app.
    /// nil means "any task", which is only usable alongside the speech
    /// heuristic — the Hub's Core ML and GGUF populations are mostly vision
    /// models and LLMs.
    var task: String? = HFHubQuery.defaultTask
    static let defaultTask = "automatic-speech-recognition"
    /// `filter=<library>` — "transformers", "whisperkit", "ctranslate2"…
    var library: String?
    /// `filter=<iso code>` — the Hub indexes languages as plain tags.
    var language: String?
    /// `filter=<format tag>` — "coreml", "gguf", "onnx", "safetensors".
    var formatTag: String?
    /// `filter=license:<id>` — the Hub indexes licences as prefixed tags.
    var license: String?
    /// `author=` — narrows to one org or user.
    var author: String?
    var sort: HFHub.Sort = .trending

    /// Are any facets beyond the default task in play?
    var hasFacets: Bool {
        library != nil || language != nil || formatTag != nil || license != nil
            || author != nil || task != HFHubQuery.defaultTask
    }

    mutating func clearFacets() {
        library = nil; language = nil; formatTag = nil; license = nil; author = nil
        task = HFHubQuery.defaultTask
    }
}

// MARK: - Client

enum HFHub {

    /// Hub-side orderings. Every one of these is a real `sort=` key, so the
    /// list is genuinely ordered across all pages, not just within a page.
    enum Sort: String, CaseIterable, Identifiable {
        case trending, downloads, likes, recentlyUpdated, recentlyCreated
        var id: String { rawValue }
        var label: String {
            switch self {
            case .trending:        return "Trending"
            case .downloads:       return "Most downloaded"
            case .likes:           return "Most liked"
            case .recentlyUpdated: return "Recently updated"
            case .recentlyCreated: return "Newest"
            }
        }
        var symbol: String {
            switch self {
            case .trending:        return "flame"
            case .downloads:       return "arrow.down.circle"
            case .likes:           return "heart"
            case .recentlyUpdated: return "clock.arrow.circlepath"
            case .recentlyCreated: return "sparkles"
            }
        }
        var hubKey: String {
            switch self {
            case .trending:        return "trendingScore"
            case .downloads:       return "downloads"
            case .likes:           return "likes"
            case .recentlyUpdated: return "lastModified"
            case .recentlyCreated: return "createdAt"
            }
        }
    }

    /// Speech-adjacent tasks worth offering. Kept short on purpose: the whole
    /// app is dictation, and a task picker listing 60 vision pipelines would be
    /// noise.
    static let tasks: [(id: String, label: String)] = [
        ("automatic-speech-recognition", "Speech recognition"),
        ("audio-classification",         "Audio classification"),
        ("voice-activity-detection",     "Voice activity detection"),
        ("audio-to-audio",               "Audio to audio"),
        ("text-to-speech",               "Text to speech"),
    ]

    /// Weight-format tags, in the order that matters to this app.
    static let formatTags: [(tag: String, label: String)] = [
        ("coreml",      "Core ML"),
        ("gguf",        "GGUF"),
        ("safetensors", "Safetensors"),
        ("onnx",        "ONNX"),
    ]

    /// Licences worth offering as a facet — the ones speech repos actually use.
    static let licenses: [(id: String, label: String)] = [
        ("mit",           "MIT"),
        ("apache-2.0",    "Apache 2.0"),
        ("bsd-3-clause",  "BSD 3-Clause"),
        ("cc-by-4.0",     "CC BY 4.0"),
        ("cc-by-nc-4.0",  "CC BY-NC 4.0"),
        ("gpl-3.0",       "GPL 3.0"),
        ("openrail",      "OpenRAIL"),
        ("llama3.1",      "Llama 3.1"),
        ("other",         "Other"),
    ]

    static let libraries: [(id: String, label: String)] = [
        ("whisperkit",   "WhisperKit"),
        ("transformers", "Transformers"),
        ("ctranslate2",  "CTranslate2"),
        ("nemo",         "NeMo"),
        ("espnet",       "ESPnet"),
        ("mlx",          "MLX"),
        ("onnx",         "ONNX"),
    ]

    /// One page of results plus the cursor for the next one.
    struct Page {
        let models: [HFHubModel]
        let nextCursor: String?
    }

    /// Fields requested from the Hub. Everything the result type carries comes
    /// from exactly one of these.
    private static let expandFields = [
        "author", "cardData", "createdAt", "downloads", "downloadsAllTime", "gated",
        "gguf", "lastModified", "library_name", "likes", "pipeline_tag", "private",
        "safetensors", "sha", "siblings", "tags", "trendingScore",
        "baseModels", "evalResults", "inferenceProviderMapping",
    ]

    /// Run one search. `cursor` continues a previous page.
    static func search(_ query: HFHubQuery, cursor: String? = nil,
                       limit: Int = 30) async throws -> Page {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: query.sort.hubKey),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { items.append(URLQueryItem(name: "search", value: text)) }
        if let task = query.task { items.append(URLQueryItem(name: "pipeline_tag", value: task)) }
        // Repeated `filter=` values are AND-ed by the Hub.
        for value in [query.library, query.language, query.formatTag,
                      query.license.map { "license:\($0)" }].compactMap({ $0 }) {
            items.append(URLQueryItem(name: "filter", value: value))
        }
        if let author = query.author, !author.isEmpty {
            items.append(URLQueryItem(name: "author", value: author))
        }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        items += expandFields.map { URLQueryItem(name: "expand[]", value: $0) }
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        // A token raises the rate limit and reveals repos the user has access
        // to; searching works fine without one.
        if let token = Keychain.getToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw SearchError.http(http.statusCode) }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return Page(models: arr.compactMap(parse), nextCursor: nextCursor(from: http))
    }

    /// One page of results across every format this app can install, deduped.
    ///
    /// The Hub AND-s repeated `filter=` values, so "Core ML or GGUF" is two
    /// requests. A text query additionally asks each format without the task
    /// filter and screens those for speech, because quantized repos routinely
    /// ship with no `pipeline_tag` — the app's own `ggml-org/Qwen3-ASR-1.7B-GGUF`
    /// among them. Untargeted browsing skips the untagged branches: with no
    /// query to narrow them they return the Hub's vision and LLM population.
    ///
    /// Throws only when every branch failed; a partial result is still useful.
    static func searchInstallable(_ query: HFHubQuery, limit: Int = 30) async throws -> [HFHubModel] {
        let formats: [String?] = query.formatTag.map { [$0] } ?? ["coreml", "gguf"]
        var branches: [(format: String?, task: String?)] = formats.map { ($0, query.task) }
        let hasText = !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText, query.task != nil { branches += formats.map { ($0, nil) } }

        let collected = await withTaskGroup(of: Result<[HFHubModel], Error>.self) { group in
            for branch in branches {
                group.addTask {
                    var branchQuery = query
                    branchQuery.formatTag = branch.format
                    branchQuery.task = branch.task
                    do {
                        let page = try await search(branchQuery, limit: limit)
                        return .success(branch.task == nil
                                        ? page.models.filter(\.looksLikeSpeech)
                                        : page.models)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var models: [HFHubModel] = []
            var failure: Error?
            for await result in group {
                switch result {
                case .success(let page): models += page
                case .failure(let error): failure = error
                }
            }
            return (models, failure)
        }
        if collected.0.isEmpty, let failure = collected.1 { throw failure }
        var seen = Set<String>()
        return collected.0.filter { seen.insert($0.repoId).inserted }
    }

    enum SearchError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(429): return "Hugging Face is rate-limiting this Mac. Adding a token in Settings raises the limit."
            case .http(let code): return "Hugging Face returned HTTP \(code)."
            }
        }
    }

    /// The Hub paginates with `Link: <url…&cursor=…>; rel="next"`.
    private static func nextCursor(from http: HTTPURLResponse) -> String? {
        guard let link = http.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            guard part.contains("rel=\"next\""),
                  let start = part.firstIndex(of: "<"),
                  let end = part.firstIndex(of: ">"), start < end else { continue }
            let urlString = String(part[part.index(after: start)..<end])
            guard let comps = URLComponents(string: urlString) else { continue }
            return comps.queryItems?.first { $0.name == "cursor" }?.value
        }
        return nil
    }

    // MARK: Parsing

    /// The Hub stamps dates as "2026-08-19T16:57:48.000Z". `ISO8601DateFormatter`
    /// rejects the fractional seconds unless asked for them, so both spellings
    /// are tried — without this every date silently parses as nil and the UI
    /// shows "—" for models that do publish one.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractionalISO.date(from: raw) ?? plainISO.date(from: raw)
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainISO = ISO8601DateFormatter()

    private static func parse(_ dict: [String: Any]) -> HFHubModel? {
        guard let repoId = dict["id"] as? String else { return nil }
        let parts = repoId.split(separator: "/").map(String.init)
        let author = (dict["author"] as? String) ?? parts.first ?? repoId
        let name = parts.count > 1 ? parts[1] : repoId

        let rawTags = (dict["tags"] as? [String]) ?? []
        let lower = rawTags.map { $0.lowercased() }
        let card = dict["cardData"] as? [String: Any]

        // Languages: the card's structured field first, `language:xx` tags
        // second. README prose is never parsed (§15).
        var languages: [String] = []
        if let list = card?["language"] as? [String] { languages = list }
        else if let one = card?["language"] as? String { languages = [one] }
        if languages.isEmpty {
            languages = lower.filter { $0.hasPrefix("language:") }.map { String($0.dropFirst(9)) }
        }
        languages = languages.map { $0.lowercased() }.filter { !$0.isEmpty }

        let license = (card?["license"] as? String)
            ?? lower.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }

        // Parameters: safetensors for PyTorch repos, gguf for quantized ones.
        var parameterCount: Int64?
        var precisions: [String: Int64] = [:]
        if let st = dict["safetensors"] as? [String: Any] {
            parameterCount = (st["total"] as? NSNumber)?.int64Value
            if let params = st["parameters"] as? [String: Any] {
                for (k, v) in params { precisions[k] = (v as? NSNumber)?.int64Value ?? 0 }
            }
        }
        var ggufBytes: Int64?
        if let gg = dict["gguf"] as? [String: Any] {
            ggufBytes = (gg["totalFileSize"] as? NSNumber)?.int64Value
            if parameterCount == nil { parameterCount = (gg["total"] as? NSNumber)?.int64Value }
        }

        var baseModels: [String] = []
        var relation: String?
        if let bm = dict["baseModels"] as? [String: Any] {
            relation = bm["relation"] as? String
            baseModels = ((bm["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }

        let evals: [HFEvalResult] = ((dict["evalResults"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let data = entry["data"] as? [String: Any],
                  let ds = data["dataset"] as? [String: Any],
                  let datasetId = ds["id"] as? String,
                  let taskId = ds["task_id"] as? String,
                  let value = (data["value"] as? NSNumber)?.doubleValue else { return nil }
            return HFEvalResult(
                datasetId: datasetId,
                taskId: taskId,
                value: value,
                date: data["date"] as? String,
                sourceName: (data["source"] as? [String: Any])?["name"] as? String,
                verified: (entry["verified"] as? Bool) ?? false
            )
        }

        let providers: [HFInferenceProvider] = ((dict["inferenceProviderMapping"] as? [[String: Any]]) ?? [])
            .compactMap { entry in
                guard let provider = entry["provider"] as? String else { return nil }
                return HFInferenceProvider(provider: provider,
                                           status: (entry["status"] as? String) ?? "unknown",
                                           task: entry["task"] as? String)
            }

        // `gated` is `false` or one of the strings "auto" / "manual".
        let gatedRaw = dict["gated"]
        let gatedKind = gatedRaw as? String
        let isGated = (gatedKind.map { !$0.isEmpty && $0 != "false" }) ?? ((gatedRaw as? Bool) ?? false)

        let files = ((dict["siblings"] as? [[String: Any]]) ?? [])
            .compactMap { $0["rfilename"] as? String }

        return HFHubModel(
            repoId: repoId,
            author: author,
            name: name,
            prettyName: card?["pretty_name"] as? String,
            pipelineTag: dict["pipeline_tag"] as? String,
            libraryName: dict["library_name"] as? String,
            license: license,
            tags: rawTags.filter { !$0.contains(":") },
            rawTags: rawTags,
            languages: languages,
            downloads30d: (dict["downloads"] as? Int) ?? 0,
            downloadsAllTime: (dict["downloadsAllTime"] as? Int) ?? 0,
            likes: (dict["likes"] as? Int) ?? 0,
            trendingScore: (dict["trendingScore"] as? NSNumber)?.intValue ?? 0,
            createdAt: parseDate(dict["createdAt"] as? String),
            lastModified: parseDate(dict["lastModified"] as? String),
            sha: dict["sha"] as? String,
            isGated: isGated,
            gatedKind: isGated ? gatedKind : nil,
            isPrivate: (dict["private"] as? Bool) ?? false,
            parameterCount: parameterCount,
            precisions: precisions,
            ggufBytes: ggufBytes,
            fileNames: files,
            baseModels: baseModels,
            baseModelRelation: relation,
            evals: evals,
            inferenceProviders: providers
        )
    }

    // MARK: Formatting

    /// "6.8M", "3.3K", "412" — compact counts for the stat strip.
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1e6) }
        if d >= 10_000 { return String(format: "%.0fK", d / 1e3) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1e3) }
        return String(n)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func exact(_ date: Date?) -> String {
        guard let date else { return "—" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}

// MARK: - Search state

/// Drives the browse sheet: debounced queries, cursor pagination, and the
/// pasted-URL fast path.
///
/// One request is in flight at a time and every response carries the token of
/// the query that asked for it, so a slow first page can never overwrite the
/// results of a query the user has since refined.
///
/// The Hub AND-s repeated `filter=` values, so there is no single query for
/// "Core ML or GGUF". Browsing what this app can run therefore fans out one
/// request per installable format and merges the pages — otherwise a search
/// like "whisper" returns a trending page of PyTorch repos with a single
/// usable model buried in it, which is what made search look broken.
@MainActor
final class HFHubSearchModel: ObservableObject {
    /// Which slice of the Hub the sheet is showing.
    enum Scope: String, CaseIterable, Identifiable {
        /// Formats a shipped runtime can load.
        case installable
        /// The whole Hub, unsupported formats included and labelled.
        case everything
        var id: String { rawValue }
        var label: String {
            switch self {
            case .installable: return "Runs here"
            case .everything:  return "Everything"
            }
        }
    }

    @Published var query = HFHubQuery()
    @Published private(set) var scope: Scope = .installable
    /// Everything fetched so far for the current query, in the active order.
    @Published private(set) var results: [HFHubModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    /// Set when the search box holds something that parses as a repo id, so the
    /// sheet can offer to open it directly.
    @Published private(set) var pastedRepoId: String?

    /// One cursor per fanned-out branch; nil once that branch is exhausted.
    private var cursors: [Branch: String?] = [:]
    private var token = 0
    private var debounce: Task<Void, Never>?
    /// The text the current results were fetched for, so a binding that
    /// re-publishes the same string (seeding the field, a re-render) doesn't
    /// fire a second identical search.
    private var lastSearchedText: String?

    var isEmpty: Bool { results.isEmpty && !isLoading }

    /// Results this app can actually install.
    var installable: [HFHubModel] { results.filter(\.canInstall) }
    var unsupportedCount: Int { results.count - installable.count }
    /// What the sheet renders for the active scope.
    var visible: [HFHubModel] { scope == .installable ? installable : results }

    /// One fanned-out request: a weight format and a task, either of which may
    /// be absent.
    private struct Branch: Hashable {
        let formatTag: String?
        let task: String?
        /// A branch that dropped the task filter can return anything the Hub
        /// has in that format, so its results are screened for speech.
        var needsSpeechScreen: Bool { task == nil }
    }

    /// The requests that make up one search.
    ///
    /// The Hub AND-s repeated `filter=` values, so "Core ML or GGUF" is two
    /// requests. On top of that, quantized repos routinely ship without a
    /// `pipeline_tag` — the app's own GGUF model repo included — so a text
    /// search also asks each format without the task filter and screens those
    /// results with `looksLikeSpeech`. Untargeted browsing skips those extra
    /// branches: with no query to narrow them they return the Hub's vision and
    /// LLM population, not speech models.
    private var branches: [Branch] {
        let formats: [String?] = {
            if let explicit = query.formatTag { return [explicit] }
            return scope == .installable ? ["coreml", "gguf"] : [nil]
        }()
        var out = formats.map { Branch(formatTag: $0, task: query.task) }
        let hasText = !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText, query.task != nil, scope == .installable {
            out += formats.map { Branch(formatTag: $0, task: nil) }
        }
        return out
    }

    // MARK: Driving

    func setScope(_ new: Scope) {
        guard new != scope else { return }
        scope = new
        reloadNow()
    }

    /// Re-run after a keystroke, with a short debounce.
    func queryChanged() {
        pastedRepoId = HFModelSearch.parseRepoReference(query.text)
        guard query.text != lastSearchedText else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Re-run immediately — facet changes, sort changes, Return, Retry.
    func reloadNow() {
        debounce?.cancel()
        // Claimed here rather than inside `reload`, so the `onChange` that a
        // programmatic text edit fires doesn't queue a second identical search
        // behind this one.
        lastSearchedText = query.text
        Task { await reload() }
    }

    /// First load, with the text the sheet was opened with.
    func seed(_ text: String) async {
        lastSearchedText = text
        query.text = text
        pastedRepoId = HFModelSearch.parseRepoReference(text)
        await reload()
    }

    func reload() async {
        token += 1
        let mine = token
        cursors = [:]
        lastSearchedText = query.text
        isLoading = true
        error = nil
        defer { if mine == token { isLoading = false } }

        let fetched = await fetch(branches.map { ($0, nil) })
        guard mine == token else { return }

        if fetched.models.isEmpty, let failure = fetched.failure {
            results = []
            hasMore = false
            self.error = (failure as NSError).code == NSURLErrorNotConnectedToInternet
                ? "You're offline. Connect to search Hugging Face."
                : failure.localizedDescription
            return
        }
        // A partial fan-out is still a useful result; only a total failure is
        // an error the user has to see.
        cursors = fetched.cursors
        results = sortLocally(dedupe(fetched.models))
        hasMore = cursors.values.contains { $0 != nil }
    }

    /// Append the next page of every branch that still has one.
    func loadMore() {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        let mine = token
        isLoadingMore = true
        Task {
            defer { if mine == token { isLoadingMore = false } }
            let pending = cursors.compactMap { branch, cursor -> (Branch, String?)? in
                guard let cursor else { return nil }
                return (branch, cursor)
            }
            guard !pending.isEmpty else { return }
            let fetched = await fetch(pending)
            guard mine == token else { return }
            for (branch, cursor) in fetched.cursors { cursors[branch] = cursor }
            results = sortLocally(dedupe(results + fetched.models))
            hasMore = cursors.values.contains { $0 != nil }
        }
    }

    /// Runs the given branches concurrently and screens the untagged ones.
    private func fetch(_ requests: [(Branch, String?)])
        async -> (models: [HFHubModel], cursors: [Branch: String?], failure: Error?) {
        let baseQuery = query
        return await withTaskGroup(
            of: (Branch, [HFHubModel], String?, Error?).self
        ) { group in
            for (branch, cursor) in requests {
                group.addTask {
                    var branchQuery = baseQuery
                    branchQuery.formatTag = branch.formatTag
                    branchQuery.task = branch.task
                    do {
                        let page = try await HFHub.search(branchQuery, cursor: cursor)
                        let models = branch.needsSpeechScreen
                            ? page.models.filter(\.looksLikeSpeech)
                            : page.models
                        return (branch, models, page.nextCursor, nil)
                    } catch {
                        return (branch, [], nil, error)
                    }
                }
            }
            var models: [HFHubModel] = []
            var cursors: [Branch: String?] = [:]
            var failure: Error?
            for await (branch, page, next, error) in group {
                models += page
                cursors[branch] = next
                if let error { failure = error }
            }
            return (models, cursors, failure)
        }
    }

    /// The Hub can repeat a row across a cursor boundary, and the fanned-out
    /// branches overlap by design.
    private func dedupe(_ models: [HFHubModel]) -> [HFHubModel] {
        var seen = Set<String>()
        return models.filter { seen.insert($0.repoId).inserted }
    }

    /// Merged branches arrive in per-branch order, so the combined list is
    /// re-sorted on the same key the Hub was asked for. Every field is already
    /// in hand, so this is exact for what has been fetched.
    private func sortLocally(_ models: [HFHubModel]) -> [HFHubModel] {
        switch query.sort {
        case .trending:        return models.sorted { $0.trendingScore > $1.trendingScore }
        case .downloads:       return models.sorted { $0.downloads30d > $1.downloads30d }
        case .likes:           return models.sorted { $0.likes > $1.likes }
        case .recentlyUpdated:
            return models.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .recentlyCreated:
            return models.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
    }

    /// Language codes present in the current results, for the language facet.
    var languagesInResults: [String] {
        let counts = results.flatMap(\.languages).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(40).map(\.key)
    }
}
