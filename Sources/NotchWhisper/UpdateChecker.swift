import Foundation
import SwiftUI

/// One commit in the changelog.
struct ChangelogEntry: Identifiable, Hashable {
    let sha: String
    let title: String        // first line of the commit message
    let body: String         // the rest, trimmed (often empty)
    let author: String
    let date: Date?

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
}

/// The result of asking GitHub what is on `main`.
struct AvailableUpdate: Equatable {
    let headSHA: String
    let headDate: Date?
    let commitCount: Int          // commits between this build and main (0 = unknown)
    let entries: [ChangelogEntry]
    /// True when the local build's commit isn't on GitHub (a dirty or unpushed
    /// build), so "how far behind" could not be computed — the changelog is
    /// then just the most recent commits on main.
    let baseUnknown: Bool

    var shortSHA: String { String(headSHA.prefix(7)) }

    static func == (a: AvailableUpdate, b: AvailableUpdate) -> Bool { a.headSHA == b.headSHA }
}

/// Polls the GitHub API for new commits on `main` and publishes what changed.
///
/// NotchWhisper ships as source, so "a new version" means "a new push on main".
/// The checker compares the commit baked into this build (`AppVersion.commit`)
/// against the branch tip and asks GitHub for the commit range in between.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?

    /// Automatic background checks (Settings → Updates).
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Key.autoCheck)
            if autoCheck { scheduleTimer() } else { timer?.invalidate(); timer = nil }
        }
    }

    /// A commit the user chose to skip — no banner until something newer lands.
    private var skippedSHA: String?

    private enum Key {
        static let autoCheck = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let skipped   = "updateSkippedSHA"
    }

    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private static let interval: TimeInterval = 3 * 60 * 60   // 3 hours

    private init() {
        let d = UserDefaults.standard
        autoCheck = d.object(forKey: Key.autoCheck) != nil ? d.bool(forKey: Key.autoCheck) : true
        lastCheck = d.object(forKey: Key.lastCheck) as? Date
        skippedSHA = d.string(forKey: Key.skipped)
        if autoCheck { scheduleTimer() }
    }

    /// The update the UI should surface: an available one the user hasn't skipped.
    var pendingUpdate: AvailableUpdate? {
        guard case .available(let update) = status else { return nil }
        return update.headSHA == skippedSHA ? nil : update
    }

    var isChecking: Bool { status == .checking }

    // MARK: - Scheduling

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        t.tolerance = 15 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called shortly after launch. Skips the network hit if we checked recently.
    func checkAtLaunch() {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 30 * 60 { return }
        check()
    }

    func skip(_ update: AvailableUpdate) {
        skippedSHA = update.headSHA
        UserDefaults.standard.set(update.headSHA, forKey: Key.skipped)
        objectWillChange.send()
    }

    // MARK: - The check

    func check() {
        inFlight?.cancel()
        status = .checking
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.fetchUpdate()
                guard !Task.isCancelled else { return }
                self.lastCheck = Date()
                UserDefaults.standard.set(self.lastCheck, forKey: Key.lastCheck)
                if let result {
                    self.status = .available(result)
                } else {
                    self.status = .upToDate
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Couldn't reach GitHub. Check your connection." }
        return ns.localizedDescription
    }

    // MARK: - GitHub

    enum UpdateError: Error {
        case http(Int)
        case badResponse
        var message: String {
            switch self {
            case .http(403): return "GitHub rate-limited this check. Try again in a while."
            case .http(let code): return "GitHub returned HTTP \(code)."
            case .badResponse: return "GitHub sent a response NotchWhisper couldn't read."
            }
        }
    }

    /// Returns the available update, or nil when this build is already at (or
    /// ahead of) the branch tip.
    nonisolated static func fetchUpdate() async throws -> AvailableUpdate? {
        let repo = AppVersion.repoSlug
        let branch = AppVersion.branch
        let local = AppVersion.commit

        let head: GHCommit = try await get("https://api.github.com/repos/\(repo)/commits/\(branch)")
        guard let local, local.lowercased() != head.sha.lowercased() else {
            // Same commit (or no commit stamped and nothing to compare against).
            if local != nil { return nil }
            let recent: [GHCommit] = try await get(
                "https://api.github.com/repos/\(repo)/commits?sha=\(branch)&per_page=10")
            return AvailableUpdate(headSHA: head.sha, headDate: head.commit.committer?.date,
                                   commitCount: 0, entries: recent.map(\.entry), baseUnknown: true)
        }

        // How far behind are we, and what landed in between?
        if let compare: GHCompare = try? await get(
            "https://api.github.com/repos/\(repo)/compare/\(local)...\(branch)") {
            // "behind"/"identical" means this build is at or ahead of main
            // (a local commit that was never pushed) — nothing to offer.
            if compare.status == "behind" || compare.status == "identical" { return nil }
            return AvailableUpdate(headSHA: head.sha, headDate: head.commit.committer?.date,
                                   commitCount: compare.ahead_by,
                                   entries: compare.commits.reversed().map(\.entry),
                                   baseUnknown: false)
        }

        // The local commit isn't on GitHub (dirty or unpushed build): still
        // offer the tip, with the most recent commits as the changelog.
        let recent: [GHCommit] = try await get(
            "https://api.github.com/repos/\(repo)/commits?sha=\(branch)&per_page=10")
        return AvailableUpdate(headSHA: head.sha, headDate: head.commit.committer?.date,
                               commitCount: 0, entries: recent.map(\.entry), baseUnknown: true)
    }

    private nonisolated static func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else { throw UpdateError.badResponse }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchWhisper", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw UpdateError.badResponse }
    }

    // MARK: - Wire types

    struct GHCommit: Decodable {
        let sha: String
        let commit: Detail

        struct Detail: Decodable {
            let message: String
            let author: Signature?
            let committer: Signature?
        }
        struct Signature: Decodable {
            let name: String?
            let date: Date?
        }

        var entry: ChangelogEntry {
            let lines = commit.message.split(separator: "\n", omittingEmptySubsequences: false)
            let title = lines.first.map(String.init) ?? commit.message
            let body = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ChangelogEntry(sha: sha, title: title, body: body,
                                  author: commit.author?.name ?? "unknown",
                                  date: commit.author?.date ?? commit.committer?.date)
        }
    }

    struct GHCompare: Decodable {
        let status: String
        let ahead_by: Int
        let commits: [GHCommit]
    }
}
