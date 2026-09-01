import AppKit
import Foundation

/// Downloads a commit from GitHub, builds it, swaps the running `.app` for the
/// result and relaunches.
///
/// NotchWhisper has no notarized binary to ship, so an update is a source
/// build — which is also what keeps the app's TCC grants (Microphone, Input
/// Monitoring, Accessibility) alive: `build.sh` re-signs with the same stable
/// local identity, so macOS still recognises the app afterwards. A downloaded
/// prebuilt binary would carry a different signature and reset every permission.
///
/// The user's own checkout is never touched: the source is unpacked and built
/// inside `~/Library/Caches/NotchWhisper/Updates`.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case downloading
        case extracting
        case building
        case installing
        case relaunching
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .idle, .failed: return false
            default: return true
            }
        }

        var title: String {
            switch self {
            case .idle:        return ""
            case .downloading: return "Downloading source…"
            case .extracting:  return "Unpacking…"
            case .building:    return "Building — this takes a few minutes"
            case .installing:  return "Installing…"
            case .relaunching: return "Restarting NotchWhisper…"
            case .failed:      return "Update failed"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Tail of the build output, for the disclosure panel.
    @Published private(set) var log: [String] = []

    private var task: Task<Void, Never>?
    private var activeProcess: Process?
    private static let logLines = 400

    private init() {}

    var isRunning: Bool { phase.isRunning }

    /// Everything the update needs before it starts. Returns nil when good.
    static func preflightProblem() -> String? {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            return "NotchWhisper can't replace itself in \(parent.path) — that folder isn't writable. Move the app somewhere you own (or update manually with git pull && ./build.sh)."
        }
        if !FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
            return "Xcode command line tools are required to build an update. Install them with: xcode-select --install"
        }
        return nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeProcess?.terminate()
        activeProcess = nil
        if phase.isRunning { phase = .failed("Update cancelled.") }
    }

    /// Clears a finished/failed run so the sheet can offer "Try again".
    func reset() {
        guard !isRunning else { return }
        phase = .idle
        log = []
    }

    func start(_ update: AvailableUpdate) {
        guard !isRunning else { return }
        if let problem = Self.preflightProblem() {
            phase = .failed(problem)
            return
        }
        log = []
        phase = .downloading
        let sha = update.headSHA
        let date = update.headDate
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(sha: sha, commitDate: date)
            } catch is CancellationError {
                self.phase = .failed("Update cancelled.")
            } catch {
                self.append("error: \(error.localizedDescription)")
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Steps

    private func run(sha: String, commitDate: Date?) async throws {
        let fm = FileManager.default
        let root = try Self.workRoot()
        let work = root.appendingPathComponent(String(sha.prefix(12)), isDirectory: true)
        // A SwiftPM build tree is several GB — keep exactly one around.
        for stale in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: stale)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // 1 — download the source tarball for that exact commit.
        let tarball = work.appendingPathComponent("source.tar.gz")
        try await download(sha: sha, to: tarball)
        try Task.checkCancellation()

        // 2 — unpack it.
        phase = .extracting
        append("Unpacking source…")
        try await runProcess("/usr/bin/tar", ["-xzf", tarball.path, "-C", work.path], cwd: work)
        guard let source = try Self.singleDirectory(in: work) else {
            throw UpdaterError.message("The downloaded source didn't unpack as expected.")
        }
        try? fm.removeItem(at: tarball)
        try Task.checkCancellation()

        // 3 — build it. build.sh vendors llama.cpp, resolves SwiftPM, assembles
        // and signs the .app with the same identity this copy uses.
        phase = .building
        append("Building NotchWhisper from \(String(sha.prefix(7)))…")
        // The tarball has no .git, so the provenance build.sh stamps into
        // Info.plist has to come from us — otherwise the next update check
        // wouldn't know which commit is installed.
        var buildEnv = ["NOTCHWHISPER_COMMIT": sha, "NOTCHWHISPER_REPO": AppVersion.repoSlug,
                        "NOTCHWHISPER_BRANCH": AppVersion.branch]
        if let commitDate {
            buildEnv["NOTCHWHISPER_COMMIT_DATE"] = ISO8601DateFormatter().string(from: commitDate)
        }
        try await runProcess("/bin/bash", ["build.sh"], cwd: source,
                             extraEnv: buildEnv, streamOutput: true)
        try Task.checkCancellation()

        let built = source.appendingPathComponent("build/NotchWhisper.app")
        guard fm.fileExists(atPath: built.appendingPathComponent("Contents/MacOS/NotchWhisper").path) else {
            throw UpdaterError.message("The build finished but produced no app bundle. See the build log below.")
        }

        // 4 — swap the running bundle for the new one.
        phase = .installing
        append("Installing…")
        let installed = try install(newApp: built)

        // 5 — relaunch once this process is gone.
        phase = .relaunching
        append("Restarting…")
        try relaunch(at: installed)
        // Give the watcher a moment to start before we exit.
        try? await Task.sleep(nanoseconds: 400_000_000)
        NSApp.terminate(nil)
    }

    /// Fetches the source tarball for one commit.
    private func download(sha: String, to destination: URL) async throws {
        let repo = AppVersion.repoSlug
        guard let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(sha)") else {
            throw UpdaterError.message("Bad download URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("NotchWhisper", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        append("Fetching \(url.absoluteString)")

        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw UpdaterError.message("GitHub returned HTTP \(http.statusCode) for the source download.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        append("Downloaded \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) of source.")
    }

    /// Atomically replaces the running bundle. Returns where the app now lives.
    private func install(newApp: URL) throws -> URL {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        // Stage on the SAME volume so the swap is a rename, not a copy.
        let staged = parent.appendingPathComponent(".NotchWhisper-update.app")
        if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: newApp, to: staged)
        // Anything unpacked from a download can carry the quarantine flag,
        // which would make the relaunched copy prompt Gatekeeper.
        try? runProcessSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdaterError.message("Couldn't replace \(target.lastPathComponent): \(error.localizedDescription)")
        }
        return target
    }

    /// Waits for this process to exit, then reopens the app.
    private func relaunch(at app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        /usr/bin/open "\(app.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
    }

    // MARK: - Process helpers

    private func runProcess(_ launchPath: String, _ arguments: [String], cwd: URL,
                            extraEnv: [String: String] = [:], streamOutput: Bool = false) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        // A GUI-launched app inherits a minimal PATH; build.sh needs the
        // developer tools and (for Homebrew installs) /opt/homebrew/bin.
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(path):/usr/local/bin:/opt/homebrew/bin"
        env.merge(extraEnv) { _, new in new }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer()
        if streamOutput {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = buffer.consume(data)
                guard !lines.isEmpty else { return }
                Task { @MainActor in
                    for line in lines { Updater.shared.append(line) }
                }
            }
        }

        activeProcess = process
        defer { activeProcess = nil }
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if streamOutput {
            let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            for line in buffer.flush(rest) { append(line) }
        }

        if Task.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw UpdaterError.message(
                "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed with exit code \(process.terminationStatus). See the log below."
            )
        }
    }

    private func runProcessSync(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Small helpers

    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLines { log.removeFirst(log.count - Self.logLines) }
    }

    var logText: String { log.joined(separator: "\n") }

    private static func workRoot() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let root = caches.appendingPathComponent("NotchWhisper/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The one directory a GitHub tarball unpacks into (`repo-<sha>`).
    private static func singleDirectory(in url: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return items.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? UpdaterError { return e.text }
        return error.localizedDescription
    }

    struct UpdaterError: LocalizedError {
        let text: String
        static func message(_ text: String) -> UpdaterError { UpdaterError(text: text) }
        var errorDescription: String? { text }
    }
}

/// Splits a byte stream into whole lines. Only ever touched from the pipe's
/// readability queue, which AppKit serialises for us.
private final class LineBuffer: @unchecked Sendable {
    private var pending = ""

    func consume(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        pending += text
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func flush(_ trailing: Data) -> [String] {
        var lines = consume(trailing)
        if !pending.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(pending) }
        pending = ""
        return lines
    }
}
