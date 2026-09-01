import SwiftUI

// MARK: - Models design vocabulary
//
// A small, fixed set of components shared by the Models page, the detail view
// and the lab. The rule throughout: status is always a glyph *and* words, never
// colour alone (§57), and no metric is shown without its provenance (§13).

// MARK: Status

/// The single status indicator for a model, everywhere it appears.
struct ModelStatusPill: View {
    let lifecycle: ModelLifecycle
    var compact = false

    private var tint: SwiftUI.Color {
        switch lifecycle {
        case .active, .installed:      return Tokens.Color.success
        case .downloading, .verifying, .queued, .updating: return Tokens.Color.accent
        case .paused, .corrupted:      return Tokens.Color.warn
        case .failed, .incompatible:   return Tokens.Color.danger
        case .available, .removing:    return Tokens.Color.textTert
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: lifecycle.symbol)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(label)
                .font(Tokens.TypeScale.micro)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        if case .downloading(let p) = lifecycle {
            return "Downloading \(Int((p * 100).rounded()))%"
        }
        if case .paused(let p) = lifecycle {
            return "Paused at \(Int((p * 100).rounded()))%"
        }
        return lifecycle.label
    }
}

/// Publisher / verification badge. Deliberately quiet — it informs, it doesn't
/// advertise (§29).
struct ModelTrustBadge: View {
    let trust: ModelTrust

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trust.symbol).font(.system(size: 9, weight: .semibold))
            Text(trust.label).font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(trust == .verified ? Tokens.Color.success : Tokens.Color.textSec)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(Tokens.Color.fillQuiet))
        .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .help(trust.explanation)
        .accessibilityLabel("\(trust.label). \(trust.explanation)")
    }
}

/// Compatibility verdict for this Mac.
struct CompatibilityBadge: View {
    let verdict: ModelCompatibility.Verdict
    var compact = false

    private var tint: SwiftUI.Color {
        switch verdict {
        case .recommended, .supported: return Tokens.Color.success
        case .tight:                   return Tokens.Color.warn
        case .needsMoreMemory:         return Tokens.Color.warn
        case .unsupported:             return Tokens.Color.danger
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.symbol).font(.system(size: 9, weight: .semibold))
            Text(verdict.label).font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.13)))
        .accessibilityLabel(verdict.label)
    }
}

/// A capability tag. One consistent style, no rainbow (§43).
struct CapabilityTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.TypeScale.micro)
            .foregroundStyle(Tokens.Color.textSec)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Tokens.Color.fillQuieter))
            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
    }
}

/// The award ribbon on a recommendation ("Best for your Mac").
struct AwardTag: View {
    let award: ModelAward
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: award.symbol).font(.system(size: 9, weight: .bold))
            Text(award.label).font(Tokens.TypeScale.micro.weight(.semibold))
        }
        .foregroundStyle(Tokens.Color.accent)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))
    }
}

// MARK: Metrics

/// A labelled figure. When the value is unmeasured it says so instead of
/// showing a number nobody computed.
struct MetricCell: View {
    let label: String
    let value: String
    var note: String? = nil
    var isUnknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
            Text(value)
                .font(Tokens.TypeScale.callout.weight(.medium))
                .foregroundStyle(isUnknown ? Tokens.Color.textTert : Tokens.Color.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note {
                Text(note)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A metric whose provenance is stated — but once per group, not once per cell.
///
/// Repeating "Published figure — approximate" under every number turns an
/// honesty requirement into visual noise, so the note is carried by
/// `ProvenanceFootnote` beneath the row and by the cell's tooltip.
struct ProvenanceMetric: View {
    let label: String
    let metric: RatedMetric

    var body: some View {
        MetricCell(
            label: label,
            value: metric.isKnown ? metric.display : "Not benchmarked",
            isUnknown: !metric.isKnown
        )
        .help(metric.provenance.note ?? "NotchWhisper has no figure for this model.")
    }
}

/// One line naming where a group of metrics came from.
struct ProvenanceFootnote: View {
    let metrics: [RatedMetric]

    private var text: String? {
        let sources = Set(metrics.compactMap { $0.isKnown ? $0.provenance : nil })
        if sources.contains(.measured), sources.count == 1 { return "Measured on this Mac." }
        if sources.contains(.published) || sources.contains(.estimated) {
            return "Accuracy and speed are published figures from the model card — approximate, and they vary with audio, accent and language."
        }
        if metrics.allSatisfy({ !$0.isKnown }) {
            return "No published accuracy or speed figures for this model. Run a benchmark to measure it here."
        }
        return nil
    }

    var body: some View {
        if let text {
            Text(text)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A slim horizontal meter for a 0…1 dimension.
struct DimensionBar: View {
    let value: Double?
    var tint: SwiftUI.Color = Tokens.Color.accent

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Tokens.Color.fillQuiet)
                .overlay(alignment: .leading) {
                    if let value {
                        Capsule().fill(tint)
                            .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    }
                }
        }
        .frame(height: 4)
        .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: value ?? 0)
    }
}

// MARK: Banners

/// A recoverable message with an optional action — never a dead end (§84).
struct InlineBanner: View {
    enum Kind { case info, success, warning, error }

    let kind: Kind
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    private var tint: SwiftUI.Color {
        switch kind {
        case .info:    return Tokens.Color.accent
        case .success: return Tokens.Color.success
        case .warning: return Tokens.Color.warn
        case .error:   return Tokens.Color.danger
        }
    }

    private var symbol: String {
        switch kind {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.text)
                if let message {
                    Text(message)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.x3)
            HStack(spacing: Tokens.Space.x2) {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.textSec)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(tint)
                }
            }
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Section scaffolding

/// A quiet section header: an eyebrow, an optional count, and trailing controls.
struct ModelSectionHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, count: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x3) {
            Text(title.uppercased())
                .font(Tokens.TypeScale.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)
            if let count {
                Text(count)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Download progress

/// The inline download panel. One logical installation, not one row per file.
struct DownloadProgressPanel: View {
    let job: ModelDownloadQueue.Job
    var showsControls = true
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                Text(headline)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.text)
                if let files = job.fileText {
                    Text("· \(files)")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer(minLength: 0)
                if case .failed = job.state {} else {
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(Tokens.TypeScale.captionSB)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.accent)
                }
            }

            if case .failed(let why) = job.state {
                Text(why)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                if job.bytesDone > 0 {
                    Text("Your \(ModelDownloadQueue.Job.bytes(job.bytesDone)) is kept, so resuming picks up where it stopped.")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView(value: max(0.01, min(1, job.progress)))
                    .tint(Tokens.Color.accent)
                    .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion),
                               value: job.progress)
                if !job.detailText.isEmpty {
                    Text(job.detailText)
                        .font(Tokens.TypeScale.micro)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }

            if showsControls {
                HStack(spacing: Tokens.Space.x3) {
                    switch job.state {
                    case .running:
                        controlButton("Pause", "pause.fill", onPause)
                        controlButton("Cancel", "xmark", onCancel)
                    case .paused:
                        controlButton("Resume", "play.fill", onResume)
                        controlButton("Cancel", "xmark", onCancel)
                    case .failed:
                        controlButton("Retry", "arrow.clockwise", onRetry)
                        controlButton("Cancel", "xmark", onCancel)
                    case .queued:
                        controlButton("Cancel", "xmark", onCancel)
                    case .verifying, .finished:
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion)) {
                            showDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Download details")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        }
                        .font(Tokens.TypeScale.micro)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Color.textTert)
                }
            }

            if showDetails {
                VStack(alignment: .leading, spacing: 2) {
                    detailLine("Downloaded", ModelDownloadQueue.Job.bytes(job.bytesDone))
                    detailLine("Total", job.totalBytes > 0
                               ? ModelDownloadQueue.Job.bytes(job.totalBytes) : "Unknown")
                    if job.filesTotal > 0 {
                        detailLine("Files", "\(job.filesDone) of \(job.filesTotal) complete")
                    }
                    if job.speedBps > 0 {
                        detailLine("Speed", "\(ModelDownloadQueue.Job.bytes(Int64(job.speedBps)))/s")
                    }
                    detailLine("Attempts", "\(job.attempts)")
                    if let error = job.error, !error.isEmpty {
                        detailLine("Last error", error)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.fillQuieter,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
            .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.displayName), \(headline), \(Int(job.progress * 100)) percent")
    }

    private var headline: String {
        switch job.state {
        case .queued:    return "Queued"
        case .running:   return job.isUpdate ? "Updating" : "Downloading"
        case .paused:    return "Paused"
        case .verifying: return "Verifying files"
        case .finished:  return "Installed"
        case .failed:    return "Couldn't finish downloading \(job.displayName)"
        }
    }

    private func controlButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(title).font(Tokens.TypeScale.micro.weight(.medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Color.textSec)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Tokens.TypeScale.micro)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Loading skeleton (§83)

/// Placeholder that matches the real row's shape, so the page never flashes
/// empty and never jumps when content arrives.
struct ModelRowSkeleton: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Tokens.Color.fillQuiet)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Tokens.Color.fillQuiet).frame(width: 160, height: 11)
                Capsule().fill(Tokens.Color.fillQuieter).frame(width: 220, height: 9)
            }
            Spacer()
            Capsule().fill(Tokens.Color.fillQuiet).frame(width: 68, height: 20)
        }
        .padding(Tokens.Space.x3)
        .opacity(shimmer ? 0.55 : 1)
        .onAppear {
            guard !Tokens.A11y.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Flow layout

/// Wraps its children onto as many lines as they need.
///
/// A plain `HStack` of tags clips off the right edge as soon as there are more
/// than a few — which is exactly what a 100-language model produces. This is the
/// one place the app needs a flow, so it's a small custom `Layout` rather than a
/// dependency.
struct FlowLayout: Layout {
    var spacing: CGFloat = Tokens.Space.x2
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: Filter chip

/// A removable active-filter chip (§12).
struct FilterChip: View {
    let text: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(Tokens.TypeScale.micro.weight(.medium))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove filter \(text)")
            }
        }
        .foregroundStyle(Tokens.Color.accent)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 4)
        .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))
    }
}

// MARK: Storage bar

/// Proportional usage bar with a per-model breakdown underneath.
struct StorageBar: View {
    let report: ModelStorageReport
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    private var total: Int64 { max(report.usedBytes + report.freeBytes, 1) }

    var body: some View {
        let _ = theme.theme
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(report.items.prefix(6)) { item in
                        Rectangle()
                            .fill(Tokens.Color.accent.opacity(shade(for: item)))
                            .frame(width: width(item.bytes, in: geo.size.width))
                    }
                    if report.incompleteBytes > 0 {
                        Rectangle()
                            .fill(Tokens.Color.warn.opacity(0.6))
                            .frame(width: width(report.incompleteBytes, in: geo.size.width))
                    }
                    Rectangle().fill(Tokens.Color.fillQuiet)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityLabel("\(ModelStorageReport.label(report.usedBytes)) used by models, \(ModelStorageReport.label(report.freeBytes)) free")

            HStack(spacing: Tokens.Space.x3) {
                Text("\(ModelStorageReport.label(report.usedBytes)) used")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.text)
                Text("\(ModelStorageReport.label(report.freeBytes)) available")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
            }
        }
    }

    private func width(_ bytes: Int64, in available: CGFloat) -> CGFloat {
        max(2, available * CGFloat(Double(bytes) / Double(total)))
    }

    private func shade(for item: ModelStorageReport.Item) -> Double {
        guard let index = report.items.firstIndex(where: { $0.id == item.id }) else { return 0.5 }
        return max(0.28, 0.9 - Double(index) * 0.11)
    }
}

// MARK: Small helpers

/// A borderless icon button used in headers and row overflow menus.
struct ToolbarIconButton: View {
    let icon: String
    let label: String
    var badge: Int? = nil
    /// Drops the text label, leaving the glyph plus a tooltip. The header
    /// switches to this at narrow window widths rather than wrapping.
    var iconOnly = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if !iconOnly {
                    Text(label).font(Tokens.TypeScale.captionSB).lineLimit(1).fixedSize()
                }
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Tokens.TypeScale.micro.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.onAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.Color.accent))
                }
            }
            .foregroundStyle(Tokens.Color.textSec)
            .padding(.horizontal, iconOnly ? Tokens.Space.x2 : Tokens.Space.x3)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering ? Tokens.Color.fillQuiet : .clear))
            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .onHover { hovering = $0 }
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Two-column key/value line used across the detail view's tables.
struct SpecLine: View {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            Text(label)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? Tokens.TypeScale.bodyMono : Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Tokens.Color.success : Tokens.Color.textTert)
                .accessibilityLabel("Copy \(label)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A collapsible "Advanced" / "Files" disclosure that stays out of the way (§65).
struct DisclosureSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var startsExpanded = false
    @ViewBuilder var content: () -> Content

    @State private var expanded: Bool

    init(_ title: String, subtitle: String? = nil, startsExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.startsExpanded = startsExpanded
        self.content = content
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Button {
                withAnimation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Tokens.Color.textTert)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if expanded { content() }
        }
    }
}
