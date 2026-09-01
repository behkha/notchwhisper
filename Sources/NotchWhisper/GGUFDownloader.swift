import Foundation

/// A GGUF speech model discovered on the Hub rather than shipped in the
/// catalog. The id carries everything the downloader and the loader need
/// (`gguf:<repo>|<weights>|<mmproj>`), so neither has to look anything up —
/// which matters because at download time there is no installation record yet.
struct CustomGGUFModel: Hashable {
    let repoId: String
    let weightsFile: String
    let mmprojFile: String

    static let prefix = "gguf:"

    var modelId: String { Self.makeId(repoId: repoId, weights: weightsFile, mmproj: mmprojFile) }
    var displayName: String {
        (weightsFile as NSString).deletingPathExtension
    }

    static func makeId(repoId: String, weights: String, mmproj: String) -> String {
        "\(prefix)\(repoId)|\(weights)|\(mmproj)"
    }

    static func isCustomGGUFId(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// nil when the id isn't a well-formed custom GGUF reference (including one
    /// with an empty projector, which this app can't load).
    static func parse(_ id: String) -> CustomGGUFModel? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let repo = String(parts[0]), weights = String(parts[1]), mmproj = String(parts[2])
        guard !repo.isEmpty, !weights.isEmpty, !mmproj.isEmpty else { return nil }
        return CustomGGUFModel(repoId: repo, weightsFile: weights, mmprojFile: mmproj)
    }
}

/// Downloads the two GGUF files (decoder + `mmproj`) for a `LlamaModelOption`
/// from Hugging Face into `Application Support/NotchWhisper/Models/llama/<repo>/`.
///
/// WhisperKit's downloader can't be reused here (it globs a CoreML repo layout),
/// but the shape matches: HTTP `Range` resume, byte-accurate progress published
/// to the same `AppState` fields the Whisper download UI reads.
enum GGUFDownloader {

    /// `<model storage root>/llama` — follows the configured storage location
    /// so relocating the models directory moves this engine too.
    static func root() -> URL {
        ModelStorageLocation.currentRoot.appendingPathComponent("llama", isDirectory: true)
    }

    /// `…/Models/llama/<repoId>`
    static func dir(for model: LlamaModelOption) -> URL {
        root().appendingPathComponent(model.repoId, isDirectory: true)
    }

    static func modelPath(for model: LlamaModelOption) -> URL {
        dir(for: model).appendingPathComponent(model.modelFile)
    }
    static func mmprojPath(for model: LlamaModelOption) -> URL {
        dir(for: model).appendingPathComponent(model.mmprojFile)
    }
    /// Written only after BOTH files finished and were verified against their
    /// real remote size — authoritative, so `isDownloaded` never has to guess
    /// from an approximate catalog size.
    private static func completeMarker(for model: LlamaModelOption) -> URL {
        dir(for: model).appendingPathComponent(".\(model.id.replacingOccurrences(of: ":", with: "_")).complete")
    }

    /// Both GGUF files present and the completion marker written by a finished
    /// `download()`. (A partial/interrupted download has no marker.)
    static func isDownloaded(_ model: LlamaModelOption) -> Bool {
        let fm = FileManager.default
        for url in [modelPath(for: model), mmprojPath(for: model)] {
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64,
                  size > 0 else { return false }
        }
        return fm.fileExists(atPath: completeMarker(for: model).path)
    }

    static func onDiskBytes(_ model: LlamaModelOption) -> Int64 {
        let fm = FileManager.default
        var sum: Int64 = 0
        for url in [modelPath(for: model), mmprojPath(for: model)] {
            if let s = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 { sum += s }
        }
        return sum
    }

    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .badResponse(let c): return "The download server returned HTTP \(c)."
            case .transport(let m):   return m
            }
        }
    }

    /// Download both files (resuming any partial file). Publishes progress to
    /// `AppState`. Returns true on success.
    @MainActor
    static func download(_ model: LlamaModelOption) async -> Bool {
        let state = AppState.shared
        state.isDownloading = true
        state.downloadingModelId = model.id
        state.downloadLabel = "Downloading \(model.display)…"
        state.resetDownloadStats()
        state.downloadBytesTotal = model.sizeBytes
        state.downloadFilesTotal = 2      // decoder weights + audio projector
        defer {
            state.isDownloading = false
            state.downloadingModelId = nil
            state.downloadLabel = ""
        }

        try? FileManager.default.createDirectory(at: dir(for: model), withIntermediateDirectories: true)

        let files: [(URL, URL)] = [
            (model.fileURLs[0].url, modelPath(for: model)),
            (model.fileURLs[1].url, mmprojPath(for: model)),
        ]

        var priorBytes: Int64 = 0
        for (index, (remote, local)) in files.enumerated() {
            state.downloadFilesDone = index
            let sink = ProgressSink(priorBytes: priorBytes, grandTotal: model.sizeBytes)
            // Retry with backoff — resume picks up from whatever landed, so a
            // dropped connection near the end recovers instead of restarting.
            var lastError: Error?
            var ok = false
            for attempt in 1...4 {
                if Task.isCancelled { return false }
                if attempt > 1 {
                    state.downloadLabel = "Resuming \(model.display)… (attempt \(attempt)/4)"
                    do { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
                    catch { return false }        // cancelled while backing off
                }
                do {
                    try await FileFetcher.fetch(remote, to: local, progress: sink)
                    ok = true
                    break
                } catch is CancellationError {
                    // Paused or cancelled by the queue: partial bytes stay on
                    // disk so the next attempt resumes from exactly here.
                    return false
                } catch {
                    lastError = error
                    fputs("GGUFDownloader: \(local.lastPathComponent) attempt \(attempt) failed: \(error)\n", stderr)
                }
            }
            guard ok else {
                state.showToast("Download failed: \(lastError?.localizedDescription ?? "unknown error"). Click Download again to resume.")
                return false
            }
            state.downloadFilesDone = index + 1
            state.downloadLabel = "Downloading \(model.display)…"
            priorBytes += (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        }

        state.downloadProgress = 1.0
        state.downloadBytesDone = state.downloadBytesTotal

        // Both files fetched + size-verified — mark the model complete.
        let ok = FileManager.default.fileExists(atPath: modelPath(for: model).path)
            && FileManager.default.fileExists(atPath: mmprojPath(for: model).path)
        if ok { FileManager.default.createFile(atPath: completeMarker(for: model).path, contents: Data()) }
        return ok
    }

    // MARK: - Arbitrary GGUF speech models
    //
    // The shipped Qwen3-ASR catalog is three known entries; a repository found
    // through discovery is any GGUF plus its `mmproj` audio projector. Both use
    // the same transfer path — only where the file list comes from differs.

    /// `…/llama/<repoId>` for a discovered GGUF model.
    static func customDir(repoId: String) -> URL {
        root().appendingPathComponent(repoId, isDirectory: true)
    }

    static func customComplete(_ model: CustomGGUFModel) -> Bool {
        let fm = FileManager.default
        for name in [model.weightsFile, model.mmprojFile] {
            let url = customDir(repoId: model.repoId).appendingPathComponent(name)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64,
                  size > 0 else { return false }
        }
        return fm.fileExists(atPath: customMarker(model).path)
    }

    private static func customMarker(_ model: CustomGGUFModel) -> URL {
        customDir(repoId: model.repoId)
            .appendingPathComponent(".\(model.weightsFile).complete")
    }

    static func customBytes(_ model: CustomGGUFModel) -> Int64 {
        let dir = customDir(repoId: model.repoId)
        var sum: Int64 = 0
        for name in [model.weightsFile, model.mmprojFile] {
            let url = dir.appendingPathComponent(name)
            if let s = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                sum += s
            }
        }
        return sum
    }

    /// Download a discovered GGUF speech model (weights + projector).
    @MainActor
    static func downloadCustom(_ model: CustomGGUFModel, totalBytes: Int64) async -> Bool {
        let state = AppState.shared
        state.isDownloading = true
        state.downloadingModelId = model.modelId
        state.downloadLabel = "Downloading \(model.displayName)…"
        state.resetDownloadStats()
        state.downloadBytesTotal = totalBytes
        state.downloadFilesTotal = 2
        defer {
            state.isDownloading = false
            state.downloadingModelId = nil
            state.downloadLabel = ""
        }

        let dir = customDir(repoId: model.repoId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var priorBytes: Int64 = 0
        for (index, name) in [model.weightsFile, model.mmprojFile].enumerated() {
            // File names come from the Hub, so they are re-sanitized here: a
            // path component can never escape the model directory (§79).
            let safeName = (name as NSString).lastPathComponent
            guard !safeName.isEmpty, !safeName.hasPrefix(".") else { return false }
            guard let remote = URL(string: "https://huggingface.co/\(model.repoId)/resolve/main/\(safeName)")
            else { return false }
            let local = dir.appendingPathComponent(safeName)
            guard local.path.hasPrefix(dir.path) else { return false }

            state.downloadFilesDone = index
            let sink = ProgressSink(priorBytes: priorBytes, grandTotal: totalBytes)
            var ok = false
            var lastError: Error?
            for attempt in 1...4 {
                if Task.isCancelled { return false }
                if attempt > 1 {
                    state.downloadLabel = "Resuming \(model.displayName)… (attempt \(attempt)/4)"
                    do { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
                    catch { return false }
                }
                do {
                    try await FileFetcher.fetch(remote, to: local, progress: sink)
                    ok = true
                    break
                } catch is CancellationError {
                    return false
                } catch {
                    lastError = error
                    fputs("GGUFDownloader: \(safeName) attempt \(attempt) failed: \(error)\n", stderr)
                }
            }
            guard ok else {
                state.showToast("Download failed: \(lastError?.localizedDescription ?? "unknown error"). Download again to resume.")
                return false
            }
            state.downloadFilesDone = index + 1
            state.downloadLabel = "Downloading \(model.displayName)…"
            priorBytes += (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        }

        state.downloadProgress = 1.0
        state.downloadBytesDone = max(state.downloadBytesTotal, priorBytes)
        FileManager.default.createFile(atPath: customMarker(model).path, contents: Data())
        return true
    }

    static func removeCustom(_ model: CustomGGUFModel) {
        let fm = FileManager.default
        let dir = customDir(repoId: model.repoId)
        for name in [model.weightsFile, model.mmprojFile] {
            try? fm.removeItem(at: dir.appendingPathComponent((name as NSString).lastPathComponent))
        }
        try? fm.removeItem(at: customMarker(model))
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    /// Delete a model's files (both GGUFs + marker + the repo dir if empty).
    static func remove(_ model: LlamaModelOption) {
        let fm = FileManager.default
        try? fm.removeItem(at: modelPath(for: model))
        try? fm.removeItem(at: mmprojPath(for: model))
        try? fm.removeItem(at: completeMarker(for: model))
        if let contents = try? fm.contentsOfDirectory(atPath: dir(for: model).path), contents.isEmpty {
            try? fm.removeItem(at: dir(for: model))
        }
    }
}

// MARK: - Progress bookkeeping

/// Publishes byte-accurate progress to `AppState` with a smoothed speed + ETA.
/// `priorBytes` = bytes already downloaded for OTHER files in this job so the
/// combined bar is correct.
private final class ProgressSink: @unchecked Sendable {
    private let priorBytes: Int64
    private let grandTotal: Int64
    private var lastTick = Date()
    private var lastBytes: Int64
    private var speedEMA: Double = 0

    init(priorBytes: Int64, grandTotal: Int64) {
        self.priorBytes = priorBytes
        self.grandTotal = grandTotal
        self.lastBytes = priorBytes
    }

    func update(fileBytes: Int64) {
        let doneTotal = priorBytes + fileBytes
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        guard dt > 0.4 else { return }
        let inst = Double(doneTotal - lastBytes) / dt
        speedEMA = speedEMA == 0 ? inst : speedEMA * 0.7 + inst * 0.3
        lastBytes = doneTotal
        lastTick = now
        let total = grandTotal
        let speed = speedEMA
        Task { @MainActor in
            let s = AppState.shared
            s.downloadBytesDone = doneTotal
            s.downloadSpeedBps = speed
            if total > 0 {
                s.downloadProgress = min(0.995, Double(doneTotal) / Double(total))
                s.downloadEtaSeconds = speed > 1024 ? Double(max(0, total - doneTotal)) / speed : 0
            }
        }
    }
}

// MARK: - Resumable file download

/// Streams one file straight to `local` with a `URLSessionDataTask`, appending
/// each received chunk to the file handle so **partial bytes are always on
/// disk** — a stalled or killed download resumes from exactly where it stopped
/// via an HTTP `Range` request. (A plain `URLSessionDownloadTask` keeps its
/// partial in a private temp that is discarded on failure — no resume.)
private final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let destination: URL
    private let expectedTotal: Int64        // real remote size, or 0 if unknown
    private let rangeHeader: String?
    private let startOffset: Int64          // bytes already on disk we're resuming past
    private let progress: ProgressSink

    private var handle: FileHandle?
    private var received: Int64 = 0         // bytes written this run
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    /// The in-flight transfer, so a pause/cancel can actually stop the socket
    /// rather than leaving it draining in the background.
    private var task: URLSessionTask?
    private var cancelledByUs = false
    private let lock = NSLock()

    private init(destination: URL, expectedTotal: Int64, startOffset: Int64,
                 rangeHeader: String?, progress: ProgressSink) {
        self.destination = destination
        self.expectedTotal = expectedTotal
        self.startOffset = startOffset
        self.rangeHeader = rangeHeader
        self.progress = progress
    }

    static func fetch(_ remote: URL, to local: URL, progress: ProgressSink) async throws {
        let fm = FileManager.default
        var existing: Int64 = 0
        if let s = (try? fm.attributesOfItem(atPath: local.path))?[.size] as? Int64, s > 0 {
            existing = s
        }

        // Real remote size — so an already-complete file is skipped without a
        // GET (a `Range:` past EOF returns 416, which used to abort the whole
        // download: the "click Download again, notch flashes" bug).
        let total = try await remoteSize(remote)
        if total > 0 {
            if existing >= total {
                if existing > total { try? fm.removeItem(at: local) }   // oversized/corrupt
                else { progress.update(fileBytes: existing); return }   // complete
                existing = 0
            }
        }

        if existing == 0 { try? fm.removeItem(at: local) }
        if !fm.fileExists(atPath: local.path) { fm.createFile(atPath: local.path, contents: nil) }

        var request = URLRequest(url: remote)
        request.timeoutInterval = 120
        let rangeHeader = existing > 0 ? "bytes=\(existing)-" : nil
        if let rangeHeader { request.setValue(rangeHeader, forHTTPHeaderField: "Range") }

        let fetcher = FileFetcher(destination: local, expectedTotal: total,
                                  startOffset: existing, rangeHeader: rangeHeader, progress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90      // stall guard: no data for 90 s → error → retry
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: fetcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // Cancelling the enclosing Task (the queue's Pause / Cancel) tears the
        // socket down immediately. Whatever already reached the file stays
        // there, so the next attempt resumes with a Range request.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                fetcher.continuation = cont
                let task = session.dataTask(with: request)
                fetcher.adopt(task)
                task.resume()
            }
        } onCancel: {
            fetcher.cancelTransfer()
        }
    }

    /// Take ownership of the transfer, cancelling it straight away if the
    /// enclosing Task was already cancelled before the task started.
    private func adopt(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelledByUs
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    private func cancelTransfer() {
        lock.lock()
        cancelledByUs = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private var wasCancelledByUs: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledByUs
    }

    /// Real remote size via HEAD (URLSession follows the HF→CDN 302; the final
    /// 200 carries the true `Content-Length`). Falls back to a 1-byte Range GET.
    private static func remoteSize(_ url: URL) async throws -> Int64 {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        if let (_, resp) = try? await URLSession.shared.data(for: head),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let len = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? ""), len > 0 {
            return len
        }
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: probe),
              let http = resp as? HTTPURLResponse else { return 0 }
        if http.statusCode == 206,
           let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last
                        .flatMap({ Int64($0) }) {
            return total
        }
        if http.statusCode == 200,
           let len = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") {
            return len
        }
        return 0
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        try? handle?.close()
        handle = nil
        switch result {
        case .success: continuation?.resume()
        case .failure(let e): continuation?.resume(throwing: e)
        }
        continuation = nil
    }

    // HF `resolve/…` 302s to a CDN — carry the Range header across the hop.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let rangeHeader else { completionHandler(request); return }
        var req = request
        req.setValue(rangeHeader, forHTTPHeaderField: "Range")
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch code {
            case 416:
                // Range past EOF → the file on disk is already complete.
                if (try? destination.checkResourceIsReachable()) == true,
                   let s = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64,
                   s > 0 {
                    completionHandler(.cancel)
                    settle(.success(()))
                } else {
                    completionHandler(.cancel)
                    settle(.failure(GGUFDownloader.DownloadError.badResponse(416)))
                }
                return
            case 206:
                let h = try FileHandle(forWritingTo: destination)
                try h.seek(toOffset: UInt64(startOffset))
                self.handle = h
            case 200:
                // Server ignored Range (or a fresh download) — write from 0.
                let h = try FileHandle(forWritingTo: destination)
                try h.truncate(atOffset: 0)
                self.handle = h
            default:
                completionHandler(.cancel)
                settle(.failure(GGUFDownloader.DownloadError.badResponse(code)))
                return
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            progress.update(fileBytes: startOffset + received)
        } catch {
            settle(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                // Distinguish "we pulled the plug" (pause/cancel — the awaiting
                // caller still needs an answer) from a 416/short-circuit that
                // already settled the continuation.
                if wasCancelledByUs { settle(.failure(CancellationError())) }
                return
            }
            settle(.failure(GGUFDownloader.DownloadError.transport(error.localizedDescription)))
            return
        }
        // Success — verify the file reached the expected size.
        try? handle?.close()
        handle = nil
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
        if expectedTotal > 0, onDisk < expectedTotal {
            settle(.failure(GGUFDownloader.DownloadError.transport(
                "connection closed early (\(onDisk) of \(expectedTotal) bytes)")))
        } else {
            settle(.success(()))
        }
    }
}
