import SwiftUI

/// Everything a row or card can do, handed down from the page so the same
/// components serve the installed list, the recommendations and discovery.
struct ModelActions {
    var activate: (String) -> Void = { _ in }
    var install: (ModelDescriptor) -> Void = { _ in }
    var openDetails: (ModelDescriptor) -> Void = { _ in }
    var test: (String) -> Void = { _ in }
    var benchmark: (String) -> Void = { _ in }
    var compare: (String) -> Void = { _ in }
    var requestRemove: (ModelDescriptor) -> Void = { _ in }
    var repair: (ModelDescriptor) -> Void = { _ in }
    var update: (ModelDescriptor) -> Void = { _ in }
    var reveal: (ModelDescriptor) -> Void = { _ in }
    var toggleFavorite: (String) -> Void = { _ in }
    var openRepository: (ModelDescriptor) -> Void = { _ in }
    var copyIdentifier: (ModelDescriptor) -> Void = { _ in }
    var pause: (String) -> Void = { _ in }
    var resume: (String) -> Void = { _ in }
    var cancel: (String) -> Void = { _ in }
    var retry: (String) -> Void = { _ in }
}

// MARK: - Primary action button

/// The one button whose label follows the model's state (§6).
struct ModelPrimaryButton: View {
    let model: ModelDescriptor
    let lifecycle: ModelLifecycle
    let actions: ModelActions
    var prominent = false

    var body: some View {
        Group {
            switch lifecycle {
            case .active:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
                    Text("Active").font(Tokens.TypeScale.captionSB)
                }
                .foregroundStyle(Tokens.Color.success)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .background(Capsule().fill(Tokens.Color.success.opacity(0.14)))
                .accessibilityLabel("\(model.displayName) is the active model")

            case .installed:
                button("Use", "checkmark.circle") { actions.activate(model.id) }

            case .available:
                button(prominent ? "Download" : "Download", "arrow.down.circle.fill") {
                    actions.install(model)
                }

            case .paused:
                button("Resume", "play.fill") { actions.resume(model.id) }

            case .failed:
                button("Retry", "arrow.clockwise") { actions.retry(model.id) }

            case .corrupted:
                button("Repair", "wrench.and.screwdriver") { actions.repair(model) }

            case .incompatible:
                button("Details", "info.circle") { actions.openDetails(model) }

            case .queued, .downloading, .verifying, .updating, .removing:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(lifecycle.primaryActionLabel).font(Tokens.TypeScale.captionSB)
                }
                .foregroundStyle(Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .accessibilityLabel("\(model.displayName): \(lifecycle.label)")
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(Tokens.TypeScale.captionSB)
            }
            .foregroundStyle(prominent ? Tokens.Color.onAccent : Tokens.Color.accent)
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent
                               ? AnyShapeStyle(Tokens.Color.accentGradient)
                               : AnyShapeStyle(Tokens.Color.accent.opacity(0.14)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .accessibilityLabel("\(title) \(model.displayName)")
    }
}

// MARK: - Overflow menu

/// Secondary actions, kept behind `•••` so a row shows one primary action (§6).
struct ModelOverflowMenu: View {
    let model: ModelDescriptor
    let lifecycle: ModelLifecycle
    let actions: ModelActions
    @ObservedObject private var registry = ModelRegistry.shared

    var body: some View {
        Menu {
            Button("Model details") { actions.openDetails(model) }
            if lifecycle.isInstalled {
                Button("Test model…") { actions.test(model.id) }
                Button(ModelBenchmarkService.shared.result(for: model.id) == nil
                       ? "Run benchmark…" : "Re-run benchmark…") { actions.benchmark(model.id) }
                Button("Compare with…") { actions.compare(model.id) }
                Divider()
                Button(registry.isFavorite(model.id) ? "Remove from favorites" : "Add to favorites") {
                    actions.toggleFavorite(model.id)
                }
                Button("Reveal in Finder") { actions.reveal(model) }
                Button("Check for update") { actions.update(model) }
            }
            Divider()
            Button("Open repository") { actions.openRepository(model) }
            Button("Copy model identifier") { actions.copyIdentifier(model) }
            if lifecycle.isInstalled || lifecycle == .corrupted {
                Divider()
                Button("Remove model…", role: .destructive) { actions.requestRemove(model) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Color.textTert)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(model.displayName)")
    }
}

// MARK: - Installed row

/// One installed model. A row, not a card (§6) — dense, scannable, one action.
struct InstalledModelRow: View {
    let model: ModelDescriptor
    let lifecycle: ModelLifecycle
    let actions: ModelActions
    var isSelected = false

    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var queue = ModelDownloadQueue.shared
    @ObservedObject private var benchmarks = ModelBenchmarkService.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(alignment: .center, spacing: Tokens.Space.x3) {
                Button { actions.toggleFavorite(model.id) } label: {
                    Image(systemName: registry.isFavorite(model.id) ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(registry.isFavorite(model.id)
                                         ? Tokens.Color.warn : Tokens.Color.textTert.opacity(hovering ? 1 : 0.35))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(registry.isFavorite(model.id)
                                    ? "Remove \(model.displayName) from favorites"
                                    : "Add \(model.displayName) to favorites")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.displayName)
                            .font(Tokens.TypeScale.body.weight(.medium))
                            .foregroundStyle(Tokens.Color.text)
                            .lineLimit(1)
                        ModelStatusPill(lifecycle: lifecycle, compact: true)
                    }
                    Text(secondaryLine)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .lineLimit(1)
                }

                Spacer(minLength: Tokens.Space.x3)

                ModelPrimaryButton(model: model, lifecycle: lifecycle, actions: actions)
                ModelOverflowMenu(model: model, lifecycle: lifecycle, actions: actions)
            }

            if let job = queue.job(for: model.id), job.state != .finished {
                DownloadProgressPanel(
                    job: job,
                    onPause: { actions.pause(model.id) },
                    onResume: { actions.resume(model.id) },
                    onCancel: { actions.cancel(model.id) },
                    onRetry: { actions.retry(model.id) }
                )
            } else if lifecycle == .corrupted {
                InlineBanner(
                    kind: .warning,
                    title: "\(model.displayName) is missing files",
                    message: "The model was interrupted or its files were changed. Repairing downloads it again.",
                    actionTitle: "Repair",
                    action: { actions.repair(model) }
                )
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, Tokens.Space.x3)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(isSelected ? Tokens.Color.accent.opacity(0.10)
                      : (hovering ? Tokens.Color.fillQuieter : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(isSelected ? Tokens.Color.accent.opacity(0.35) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Tokens.Motion.hover, value: hovering)
        .onTapGesture { actions.openDetails(model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.displayName), \(model.provider), \(lifecycle.label)")
        .accessibilityHint("Open model details")
    }

    private var secondaryLine: String {
        var parts: [String] = [model.provider]
        parts.append(model.capabilities.languageCountLabel)
        if model.resources.diskBytes > 0 { parts.append(model.resources.diskLabel) }
        if let result = benchmarks.result(for: model.id) {
            parts.append("\(result.rtfLabel) on this Mac")
        }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Discovery card

/// A compact card for a model that isn't installed.
struct DiscoverModelCard: View {
    let model: ModelDescriptor
    let lifecycle: ModelLifecycle
    let compatibility: ModelCompatibility
    let award: ModelAward?
    let actions: ModelActions

    @ObservedObject private var queue = ModelDownloadQueue.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(Tokens.TypeScale.title2)
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                    Text(model.provider)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ModelTrustBadge(trust: model.trust)
            }

            if let award {
                AwardTag(award: award)
            } else {
                CompatibilityBadge(verdict: compatibility.verdict)
            }

            Text(model.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                HStack(alignment: .top, spacing: Tokens.Space.x2) {
                    ProvenanceMetric(label: "Accuracy", metric: model.accuracy)
                    ProvenanceMetric(label: "Speed", metric: model.speed)
                }
                HStack(alignment: .top, spacing: Tokens.Space.x2) {
                    MetricCell(label: "Languages", value: model.capabilities.languageCountLabel)
                    MetricCell(label: "Size", value: model.resources.diskLabel,
                               isUnknown: model.resources.diskBytes == 0)
                    MetricCell(label: "Memory", value: model.resources.memoryLabel,
                               isUnknown: model.resources.memoryBytes == 0)
                }
            }

            if let job = queue.job(for: model.id), job.state != .finished {
                DownloadProgressPanel(
                    job: job,
                    onPause: { actions.pause(model.id) },
                    onResume: { actions.resume(model.id) },
                    onCancel: { actions.cancel(model.id) },
                    onRetry: { actions.retry(model.id) }
                )
            } else {
                Divider().overlay(Tokens.Color.hairline)
                HStack(spacing: Tokens.Space.x2) {
                    ModelPrimaryButton(model: model, lifecycle: lifecycle, actions: actions,
                                       prominent: award != nil)
                    Spacer(minLength: 0)
                    ModelOverflowMenu(model: model, lifecycle: lifecycle, actions: actions)
                }
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.Color.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(
                    award != nil ? Tokens.Color.accent.opacity(0.30)
                        : (hovering ? Tokens.Color.hairlineStrong : Tokens.Color.hairline),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Tokens.Motion.hover, value: hovering)
        .onTapGesture { actions.openDetails(model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.displayName) by \(model.provider). \(compatibility.verdict.label).")
    }
}

// MARK: - Recommendation card

/// A "why this one" card in the Recommended strip.
struct RecommendationCard: View {
    let recommendation: ModelRecommendation
    let lifecycle: ModelLifecycle
    let actions: ModelActions

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            AwardTag(award: recommendation.award)

            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.model.displayName)
                    .font(Tokens.TypeScale.title2)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(1)
                Text(recommendation.model.provider)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(recommendation.reasons.prefix(3)) { reason in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Tokens.Color.success)
                            .padding(.top, 2)
                        Text(reason.text)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: Tokens.Space.x2) {
                ModelPrimaryButton(model: recommendation.model, lifecycle: lifecycle,
                                   actions: actions, prominent: true)
                Spacer(minLength: 0)
                Button("Details") { actions.openDetails(recommendation.model) }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.textSec)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .fill(Tokens.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .strokeBorder(Tokens.Color.accent.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(recommendation.award.label): \(recommendation.model.displayName)")
    }
}

// MARK: - Active model panel

/// The most important thing on the page: what engine is running right now.
/// Emphasised, but deliberately not a marketing hero (§5).
struct ActiveModelPanel: View {
    let model: ModelDescriptor
    let lifecycle: ModelLifecycle
    let compatibility: ModelCompatibility
    let actions: ModelActions

    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var benchmarks = ModelBenchmarkService.shared

    var body: some View {
        let _ = theme.theme
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(alignment: .top, spacing: Tokens.Space.x3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.displayName)
                            .font(Tokens.TypeScale.title1)
                            .foregroundStyle(Tokens.Color.text)
                        engineStatus
                    }
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.provider)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                        ModelTrustBadge(trust: model.trust)
                        privacyTag
                    }
                }
                Spacer(minLength: 0)
            }

            Text(model.blurb)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                HStack(alignment: .top, spacing: Tokens.Space.x4) {
                    MetricCell(label: "Languages", value: model.capabilities.languageCountLabel)
                    MetricCell(label: "Speed",
                               value: measuredSpeed ?? (model.speed.isKnown ? model.speed.display : "Not benchmarked"),
                               isUnknown: measuredSpeed == nil && !model.speed.isKnown)
                    MetricCell(label: "Accuracy",
                               value: model.accuracy.isKnown ? model.accuracy.display : "Not benchmarked",
                               isUnknown: !model.accuracy.isKnown)
                    MetricCell(label: "Disk", value: model.resources.diskLabel,
                               isUnknown: model.resources.diskBytes == 0)
                    MetricCell(label: "Memory", value: model.resources.memoryLabel,
                               isUnknown: model.resources.memoryBytes == 0)
                }
                ProvenanceFootnote(metrics: measuredSpeed != nil
                                   ? [RatedMetric(display: "", fraction: nil, provenance: .measured)]
                                   : [model.accuracy, model.speed])
            }

            if state.isLoadingModel {
                ModelLoadBar()
            }

            HStack(spacing: Tokens.Space.x2) {
                Button { actions.openDetails(model) } label: {
                    Label("Model details", systemImage: "info.circle")
                        .font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .foregroundStyle(Tokens.Color.accent)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))

                Button { actions.test(model.id) } label: {
                    Label("Test", systemImage: "waveform.badge.mic")
                        .font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .foregroundStyle(Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))

                Button { actions.benchmark(model.id) } label: {
                    Label(benchmarks.result(for: model.id) == nil ? "Run benchmark" : "Re-run benchmark",
                          systemImage: "gauge.with.dots.needle.50percent")
                        .font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .foregroundStyle(Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))

                Spacer(minLength: 0)
                ModelOverflowMenu(model: model, lifecycle: lifecycle, actions: actions)
            }
        }
        .padding(Tokens.Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .fill(Tokens.Color.accent.opacity(0.05))
                )
        }
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .strokeBorder(Tokens.Color.accent.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active model: \(model.displayName), \(engineStatusText)")
    }

    private var measuredSpeed: String? {
        benchmarks.result(for: model.id).map { "\($0.rtfLabel) real time" }
    }

    /// Health of the running engine, in words as well as colour.
    private var engineStatusText: String {
        if state.isDownloading { return "Downloading" }
        if state.isLoadingModel { return "Loading" }
        switch state.modelStatus {
        case .ready:       return "Ready"
        case .loading:     return "Loading"
        case .downloading: return "Downloading"
        case .error:       return "Error"
        case .unknown:     return "Not loaded"
        }
    }

    private var engineStatus: some View {
        let tint: SwiftUI.Color
        let symbol: String
        switch state.modelStatus {
        case .ready:
            tint = Tokens.Color.success; symbol = "checkmark.circle.fill"
        case .loading, .downloading:
            tint = Tokens.Color.warn; symbol = "arrow.triangle.2.circlepath"
        case .error:
            tint = Tokens.Color.danger; symbol = "exclamationmark.triangle.fill"
        case .unknown:
            tint = Tokens.Color.textTert; symbol = "circle"
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(engineStatusText).font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    /// §42: privacy describes how the app *executes* the model, not its licence.
    private var privacyTag: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
            Text("On-device").font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(Tokens.Color.success)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 3)
        .background(Capsule().fill(Tokens.Color.success.opacity(0.12)))
        .help("Audio is transcribed on your Mac. Nothing is uploaded.")
    }
}
