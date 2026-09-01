import Foundation

/// What this copy of NotchWhisper was built from.
///
/// The app is distributed as source, so the meaningful identity of a build is
/// the commit it came from — `build.sh` stamps `NWGitCommit` / `NWGitCommitDate`
/// into `Info.plist`. `UpdateChecker` compares that against the tip of `main`.
enum AppVersion {
    /// GitHub repository the app updates from, as `owner/name`.
    static var repoSlug: String {
        info("NWSourceRepo") ?? "behkha/notchwhisper"
    }

    /// Branch treated as the release channel.
    static var branch: String {
        info("NWSourceBranch") ?? "main"
    }

    /// Marketing version (`CFBundleShortVersionString`), e.g. "1.0".
    static var shortVersion: String {
        info("CFBundleShortVersionString") ?? "1.0"
    }

    /// Full 40-char commit SHA this build came from, when known. A build made
    /// outside a git checkout (or from a dirty tree) reports nil.
    static var commit: String? {
        guard let sha = info("NWGitCommit")?.trimmingCharacters(in: .whitespacesAndNewlines),
              sha.count >= 7, sha.lowercased() != "unknown"
        else { return nil }
        return sha
    }

    /// True when the build was made from a working tree with uncommitted
    /// changes — comparing it to `main` is advisory only.
    static var isDirtyBuild: Bool {
        (info("NWGitDirty") ?? "0") == "1"
    }

    static var shortCommit: String {
        guard let commit else { return "unknown" }
        return String(commit.prefix(7))
    }

    /// Commit date of this build (ISO-8601 in the plist).
    static var commitDate: Date? {
        guard let raw = info("NWGitCommitDate") else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// One-line identity for the UI: "1.0 (49f9254 · 1 Sep 2026)".
    static var displayVersion: String {
        var out = shortVersion
        var detail = commit == nil ? "source build" : shortCommit
        if isDirtyBuild { detail += " · modified" }
        if let date = commitDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            detail += " · \(f.string(from: date))"
        }
        out += " (\(detail))"
        return out
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
