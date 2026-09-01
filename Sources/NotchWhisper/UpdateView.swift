import SwiftUI
import AppKit

/// The Updates window: what this build is, what's on `main`, the list of
/// commits in between, and the button that rebuilds and relaunches the app.
struct UpdateView: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @State private var showLog = false

    var body: some View {
        let _ = theme.theme
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                    SectionHeader(headline, eyebrow: "NotchWhisper", subtitle: subheadline)
                    versionCard
                    if updater.isRunning || updater.phase != .idle {
                        progressCard
                    }
                    if let update = checker.pendingUpdate ?? availableIgnoringSkip {
                        changelog(update)
                    }
                }
                .padding(Tokens.Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            footer
        }
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
        .onAppear { if case .idle = checker.status { checker.check() } }
    }

    /// The update even if the user skipped it — the window is an explicit visit,
    /// so it should still show what's there.
    private var availableIgnoringSkip: AvailableUpdate? {
        if case .available(let u) = checker.status { return u }
        return nil
    }

    private var headline: String {
        if case .failed(let msg) = updater.phase, !msg.isEmpty { return "Update failed" }
        if updater.isRunning { return "Updating" }
        switch checker.status {
        case .checking: return "Checking for updates…"
        case .available: return "Update available"
        case .upToDate: return "You're up to date"
        case .failed: return "Couldn't check for updates"
        case .idle: return "Updates"
        }
    }

    private var subheadline: String? {
        if let update = availableIgnoringSkip, !updater.isRunning {
            if update.baseUnknown {
                return "This build isn't a commit on GitHub, so NotchWhisper can't tell exactly how far behind it is. The latest work on \(AppVersion.branch) is below."
            }
            let n = update.commitCount
            return "\(n) new commit\(n == 1 ? "" : "s") on \(AppVersion.branch)."
        }
        if case .failed(let message) = checker.status { return message }
        if case .upToDate = checker.status { return "NotchWhisper matches the latest commit on \(AppVersion.branch)." }
        return nil
    }

    // MARK: Cards

    private var versionCard: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x4) {
            versionColumn("Installed", AppVersion.shortVersion,
                          detail: AppVersion.commit == nil ? "source build" : AppVersion.shortCommit,
                          date: AppVersion.commitDate, tint: Tokens.Color.textSec)
            if let update = availableIgnoringSkip {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textTert)
                    .padding(.top, 22)
                versionColumn("Latest on \(AppVersion.branch)", update.shortSHA,
                              detail: "\(update.commitCount > 0 ? "\(update.commitCount) commits ahead" : "branch tip")",
                              date: update.headDate, tint: Tokens.Color.accent)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func versionColumn(_ label: String, _ value: String, detail: String,
                               date: Date?, tint: SwiftUI.Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)
            Text(value)
                .font(Tokens.TypeScale.title1)
                .foregroundStyle(tint)
            Text(detail)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
            if let date {
                Text(Self.dayFormatter.string(from: date))
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            if case .failed(let message) = updater.phase {
                HStack(alignment: .top, spacing: Tokens.Space.x2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Color.danger)
                    Text(message)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: Tokens.Space.x2) {
                    ProgressView().controlSize(.small)
                    Text(updater.phase.title)
                        .font(Tokens.TypeScale.body.weight(.medium))
                        .foregroundStyle(Tokens.Color.text)
                    Spacer()
                }
                ProgressView().progressViewStyle(.linear).tint(Tokens.Color.accent)
            }

            if !updater.log.isEmpty {
                Button(showLog ? "Hide build log" : "Show build log") {
                    withAnimation(Tokens.Motion.ease) { showLog.toggle() }
                }
                .buttonStyle(.plain)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.accent)

                if showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(updater.log.enumerated()), id: \.offset) { i, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Tokens.Color.textSec)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(i)
                                }
                            }
                            .padding(Tokens.Space.x2)
                        }
                        .frame(height: 160)
                        .background(Tokens.Color.fillQuieter,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                        .onChange(of: updater.log.count) { _, count in
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .card()
    }

    private func changelog(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("What's new".uppercased())
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)
                .padding(.leading, Tokens.Space.x2)
            VStack(spacing: 0) {
                ForEach(Array(update.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                    }
                    commitRow(entry)
                }
                if update.entries.isEmpty {
                    Text("No commit details available.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .padding(Tokens.Space.x4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card(padding: 0)
        }
    }

    private func commitRow(_ entry: ChangelogEntry) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            IconTile(Self.icon(for: entry.title), tint: Self.tint(for: entry.title), size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Tokens.TypeScale.body.weight(.medium))
                    .foregroundStyle(Tokens.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                }
                HStack(spacing: 6) {
                    Text(entry.shortSHA)
                        .font(.system(size: 10, design: .monospaced))
                    Text("·")
                    Text(entry.author)
                    if let date = entry.date {
                        Text("·")
                        Text(Self.dayFormatter.string(from: date))
                    }
                }
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Tokens.Space.x3) {
            if checker.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            } else if let last = checker.lastCheck {
                Text("Last checked \(Self.relative.localizedString(for: last, relativeTo: Date()))")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
            Spacer()

            if updater.isRunning {
                Button("Cancel") { updater.cancel() }.secondaryAction()
            } else if case .failed = updater.phase {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(updater.logText, forType: .string)
                }
                .secondaryAction()
                if let update = availableIgnoringSkip {
                    Button("Try again") { updater.reset(); updater.start(update) }.primaryAction()
                }
            } else if let update = availableIgnoringSkip {
                Button("Skip this version") { checker.skip(update) }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Button("View on GitHub") { openCompareOnGitHub(update) }.secondaryAction()
                Button("Update & Relaunch") { updater.start(update) }.primaryAction()
            } else {
                Button("Check now") { checker.check() }.primaryAction()
            }
        }
        .padding(.horizontal, Tokens.Space.x6)
        .padding(.vertical, Tokens.Space.x4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
        }
    }

    private func openCompareOnGitHub(_ update: AvailableUpdate) {
        let repo = AppVersion.repoSlug
        let path: String
        if let local = AppVersion.commit, !update.baseUnknown {
            path = "compare/\(local)...\(update.headSHA)"
        } else {
            path = "commits/\(AppVersion.branch)"
        }
        if let url = URL(string: "https://github.com/\(repo)/\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Conventional-commit prefix → an icon, so the changelog scans at a glance.
    private static func icon(for title: String) -> String {
        switch prefix(of: title) {
        case "feat":  return "sparkles"
        case "fix":   return "wrench.adjustable"
        case "perf":  return "bolt.fill"
        case "docs":  return "book.closed.fill"
        case "test":  return "checkmark.seal.fill"
        case "refactor": return "arrow.triangle.2.circlepath"
        case "chore", "build", "ci": return "gearshape.fill"
        default:      return "circle.fill"
        }
    }

    private static func tint(for title: String) -> SwiftUI.Color {
        switch prefix(of: title) {
        case "feat": return Tokens.Color.accent
        case "fix":  return Tokens.Color.success
        case "perf": return Tokens.Color.warn
        default:     return Tokens.Color.textTert
        }
    }

    private static func prefix(of title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return "" }
        var head = String(title[title.startIndex..<colon])
        if let paren = head.firstIndex(of: "(") { head = String(head[head.startIndex..<paren]) }
        return head.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

// MARK: - Reusable "update available" banner

/// The compact affordance used in the menu-bar panel and the main window.
struct UpdateBanner: View {
    @ObservedObject private var checker = UpdateChecker.shared
    var compact = false

    var body: some View {
        if let update = checker.pendingUpdate {
            Button { AppDelegate.shared?.showUpdates() } label: {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundStyle(Tokens.Color.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
                            .font(compact ? Tokens.TypeScale.caption.weight(.semibold)
                                          : Tokens.TypeScale.body.weight(.semibold))
                            .foregroundStyle(Tokens.Color.text)
                        Text(update.commitCount > 0
                             ? "\(update.commitCount) new commit\(update.commitCount == 1 ? "" : "s") on \(AppVersion.branch)"
                             : "New work on \(AppVersion.branch) · \(update.shortSHA)")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.Color.textTert)
                }
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, compact ? 8 : Tokens.Space.x3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Tokens.Color.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.Color.accent.opacity(0.25), lineWidth: 1))
        }
    }
}
