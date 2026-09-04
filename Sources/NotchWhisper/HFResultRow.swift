import SwiftUI
import AppKit

// MARK: - One Hub search result
//
// Collapsed, the row answers "what is this and can I run it?". Expanded, it
// answers everything else the Hub knows — and lists the real installable builds
// with exact sizes, fetched only at that point (§77 stage 3).

struct HFResultRow: View {
    let model: HFHubModel
    let isExpanded: Bool
    let actions: ModelActions
    let onToggle: () -> Void
    let onOpenDetails: (ModelDescriptor) -> Void
    /// Tapping the org name narrows the search to that publisher.
    let onSearchAuthor: (String) -> Void

    @ObservedObject private var avatars = HFOrgAvatars.shared
    @ObservedObject private var metadata = HFMetadataCache.shared
    @State private var hovering = false

    private var installability: HFInstallability { model.installability }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            headline
            if classificationParts.count > 1 { classification }
            factLine
            statStrip
            if !model.evals.isEmpty { evalPills }
            if let reason = installability.reason { unsupportedNote(reason) }
            footer
            if isExpanded {
                Divider().overlay(Tokens.Color.hairline)
                HFResultDetail(model: model, actions: actions, onOpenDetails: onOpenDetails)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .fill(isExpanded ? Tokens.Color.elevated : Tokens.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .strokeBorder(isExpanded ? Tokens.Color.accent.opacity(0.28)
                          : (hovering ? Tokens.Color.hairlineStrong : Tokens.Color.hairline),
                          lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Tokens.Motion.hover, value: hovering)
        .onAppear { avatars.ensure(model.author) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Headline

    private var headline: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Button { onSearchAuthor(model.author) } label: {
                        Text(model.author)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    .buttonStyle(.plain)
                    .help("Show every model by \(model.author)")
                    Text("/").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    Text(model.name)
                        .font(Tokens.TypeScale.title2)
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if let pretty = model.prettyName, pretty != model.name {
                    Text(pretty)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.x2)
            HStack(spacing: 5) {
                if model.isGated { gatedBadge }
                if model.trendingScore > 0 { trendingBadge }
                formatBadge
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let url = avatars.avatarURL(for: model.author) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Tokens.Color.fillQuiet
                    }
                }
            } else {
                ZStack {
                    Tokens.Color.fillQuiet
                    Text(String(model.author.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var gatedBadge: some View {
        badge(icon: "lock.fill",
              text: model.gatedKind == "manual" ? "Access request" : "Gated",
              tint: Tokens.Color.warn)
            .help("This repository requires accepting terms on Hugging Face, and a token in Settings.")
    }

    private var trendingBadge: some View {
        badge(icon: "flame.fill", text: "\(model.trendingScore)", tint: Tokens.Color.accent)
            .help("Hugging Face trending score")
    }

    private var formatBadge: some View {
        badge(icon: installability.canInstall ? "checkmark.seal.fill" : "xmark.octagon.fill",
              text: installability.format.displayName,
              tint: installability.canInstall ? Tokens.Color.success : Tokens.Color.textTert)
            .help(installability.reason ?? "NotchWhisper can install this format.")
    }

    private func badge(icon: String, text: String, tint: SwiftUI.Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(Tokens.TypeScale.micro.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    // MARK: Classification / facts

    private var classification: some View {
        Text(classificationParts.joined(separator: "  ·  "))
            .font(Tokens.TypeScale.caption)
            .foregroundStyle(Tokens.Color.textSec)
            .lineLimit(1)
    }

    /// Library and task, which many quantized repos simply don't declare. With
    /// fewer than two of them the line is dropped and the licence moves down to
    /// the fact line rather than standing alone under the title.
    private var classificationParts: [String] {
        var parts: [String] = []
        if let library = model.libraryName { parts.append(library) }
        if let task = model.pipelineTag {
            parts.append(HFHub.tasks.first { $0.id == task }?.label ?? task.replacingOccurrences(of: "-", with: " "))
        }
        parts.append(licenceLabel)
        return parts
    }

    private var licenceLabel: String {
        model.license.map { $0.uppercased() } ?? "Licence unknown"
    }

    private var factLine: some View {
        Text(factParts.joined(separator: "  ·  "))
            .font(Tokens.TypeScale.caption)
            .foregroundStyle(Tokens.Color.textTert)
            .lineLimit(1)
    }

    private var factParts: [String] {
        var parts: [String] = []
        if classificationParts.count <= 1 { parts.append(licenceLabel) }
        if let params = model.parameterLabel { parts.append("\(params) parameters") }
        if let size = model.sizeLabel { parts.append(size) }
        switch model.languages.count {
        case 0: break
        case 1: parts.append(ModelCapabilities.languageName(model.languages[0]))
        default: parts.append("\(model.languages.count) languages")
        }
        parts.append("updated \(model.updatedLabel)")
        return parts
    }

    // MARK: Popularity

    /// Popularity at a glance. The all-time total is dropped when it barely
    /// differs from the 30-day one — on a young repository they are the same
    /// number, and printing it twice reads as a rendering bug. The exact dates
    /// live in the expanded panel, so the strip carries no date at all: the
    /// fact line above already says when the repository last changed.
    private var statStrip: some View {
        HStack(spacing: Tokens.Space.x4) {
            stat("arrow.down.circle", HFHub.compact(model.downloads30d), "downloads in the last 30 days")
            if model.downloadsAllTime > Int(Double(model.downloads30d) * 1.2) {
                stat("chart.line.uptrend.xyaxis", HFHub.compact(model.downloadsAllTime), "downloads all time")
            }
            stat("heart", HFHub.compact(model.likes), "likes")
            Spacer(minLength: 0)
        }
    }

    private func stat(_ icon: String, _ value: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(value).font(Tokens.TypeScale.micro.monospacedDigit())
        }
        .foregroundStyle(Tokens.Color.textTert)
        .help(help)
        .accessibilityLabel("\(value) \(help)")
    }

    /// Published benchmark numbers, always labelled as the publisher's claim.
    private var evalPills: some View {
        FlowLayout(spacing: 6) {
            ForEach(headlineEvals) { eval in
                HStack(spacing: 4) {
                    Image(systemName: eval.isSpeedFactor ? "bolt.fill" : "target")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(eval.valueLabel) \(eval.isSpeedFactor ? "" : eval.metricLabel)")
                        .font(Tokens.TypeScale.micro.weight(.semibold))
                }
                .foregroundStyle(Tokens.Color.textSec)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Tokens.Color.fillQuiet))
                .help("Published by \(eval.sourceName ?? model.author) on \(eval.datasetLabel) — not measured by NotchWhisper.")
            }
            if model.evals.count > headlineEvals.count {
                Text("+\(model.evals.count - headlineEvals.count) more")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private var headlineEvals: [HFEvalResult] {
        [model.headlineWER, model.headlineSpeed].compactMap { $0 }
    }

    private func unsupportedNote(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.Color.textTert)
                .padding(.top, 1)
            Text(reason)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Tokens.Space.x2) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(isExpanded ? "Hide details"
                         : (installability.canInstall ? "Builds & details" : "Details"))
                        .font(Tokens.TypeScale.captionSB)
                }
                .foregroundStyle(installability.canInstall ? Tokens.Color.accent : Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .background(Capsule().fill(installability.canInstall
                                           ? Tokens.Color.accent.opacity(0.14)
                                           : Tokens.Color.fillQuiet))
                .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.97))

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.repoId, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Color.textTert)
            .help("Copy \(model.repoId)")
            .accessibilityLabel("Copy repository identifier")

            Link(destination: model.repositoryURL) {
                HStack(spacing: 3) {
                    Text("Hugging Face")
                    Image(systemName: "arrow.up.right")
                }
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
            }
            .buttonStyle(.plain)
        }
    }

    private var accessibilitySummary: String {
        var text = "\(model.name) by \(model.author). \(installability.format.displayName)."
        text += installability.canInstall ? " Installable." : " Not supported: \(installability.reason ?? "")."
        text += " \(HFHub.compact(model.likes)) likes, \(HFHub.compact(model.downloads30d)) downloads this month."
        return text
    }
}
