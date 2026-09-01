import SwiftUI
import AppKit

/// The full picture of one model: what it is, where it came from, whether it
/// suits this Mac, and what it has actually done here.
///
/// The list stays deliberately thin; everything technical lives here, and the
/// most technical parts live behind disclosures inside it (§14, §65).
struct ModelDetailSheet: View {
    let model: ModelDescriptor
    let actions: ModelActions
    let onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var queue = ModelDownloadQueue.shared
    @ObservedObject private var benchmarks = ModelBenchmarkService.shared
    @ObservedObject private var metadata = HFMetadataCache.shared

    @State private var selectedVariantId: String?
    @State private var pinRevision = false
    @State private var revisionText = ""

    private let hw = HardwareInfo.current

    private var lifecycle: ModelLifecycle { registry.lifecycle(of: model.id) }
    private var compatibility: ModelCompatibility { ModelCompatibility.evaluate(model, hw: hw) }
    private var installation: ModelInstallation? { registry.installations[model.id] }
    private var repoMetadata: HFRepoMetadata? { metadata.cached(model.repositoryId) }

    /// The model the primary button acts on: a chosen variant when the user is
    /// looking at a multi-build repository, otherwise this model.
    private var effectiveModel: ModelDescriptor {
        guard let selectedVariantId, let repoMetadata,
              let variant = repoMetadata.variants.first(where: { $0.id == selectedVariantId })
        else { return model }
        return ModelCatalogService.descriptor(forVariant: variant, in: repoMetadata)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Tokens.Color.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                    if let job = queue.job(for: model.id), job.state != .finished {
                        DownloadProgressPanel(
                            job: job,
                            onPause: { actions.pause(model.id) },
                            onResume: { actions.resume(model.id) },
                            onCancel: { actions.cancel(model.id) },
                            onRetry: { actions.retry(model.id) }
                        )
                    }
                    updateBanner
                    overviewSection
                    compatibilitySection
                    performanceSection
                    capabilitiesSection
                    variantsSection
                    trustSection
                    usageSection
                    filesSection
                    versionSection
                    advancedSection
                }
                .padding(Tokens.Space.x5)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 660, idealWidth: 720, maxWidth: 820,
               minHeight: 540, idealHeight: 720, maxHeight: 900)
        .background(Tokens.Color.bg)
        .environment(\.colorScheme, .dark)
        .onKeyPress(.escape) { onClose(); return .handled }
        .task {
            metadata.ensure(model.repositoryId)
            revisionText = installation?.pinnedRevision ?? ""
            pinRevision = installation?.pinnedRevision != nil
        }
    }

    // MARK: Header (§86)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(alignment: .top, spacing: Tokens.Space.x3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.displayName)
                            .font(Tokens.TypeScale.title1)
                            .foregroundStyle(Tokens.Color.text)
                        ModelStatusPill(lifecycle: lifecycle)
                    }
                    Text(model.provider)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                    Text(model.repositoryId)
                        .font(Tokens.TypeScale.bodyMono)
                        .foregroundStyle(Tokens.Color.textTert)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tokens.Color.textTert)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close model details")
            }

            HStack(spacing: Tokens.Space.x2) {
                ModelPrimaryButton(model: effectiveModel, lifecycle: registry.lifecycle(of: effectiveModel.id),
                                   actions: actions, prominent: true)
                if lifecycle.isInstalled {
                    quietButton("Test", "waveform.badge.mic") { actions.test(model.id) }
                    quietButton("Benchmark", "gauge.with.dots.needle.50percent") { actions.benchmark(model.id) }
                    if registry.installedIds.count >= 2 {
                        quietButton("Compare", "square.split.2x1") { actions.compare(model.id) }
                    }
                }
                Spacer(minLength: 0)
                ModelOverflowMenu(model: model, lifecycle: lifecycle, actions: actions)
            }
        }
        .padding(Tokens.Space.x5)
    }

    private func quietButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.97))
    }

    // MARK: Update (§31)

    @ViewBuilder
    private var updateBanner: some View {
        if let installation, let update = metadata.updateAvailable(for: installation) {
            InlineBanner(
                kind: .info,
                title: "Update available",
                message: "Installed \(update.installed) · latest \(update.latest). Your current version keeps working until you choose to update.",
                actionTitle: "Update",
                action: { queue.enqueue(model, isUpdate: true, activate: model.id == registry.activeId) },
                secondaryTitle: "Keep current version",
                secondaryAction: { registry.pin(model.id, revision: installation.commitSha) }
            )
        }
    }

    // MARK: Overview (§64)

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            sectionTitle("Overview")
            Text(model.blurb)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
            if !model.recommendation.isEmpty {
                Text(model.recommendation)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout {
                ForEach(model.tags, id: \.self) { CapabilityTag(text: $0) }
            }
            Button {
                NSWorkspace.shared.open(model.modelCardURL)
            } label: {
                HStack(spacing: 4) {
                    Text("View model card on Hugging Face")
                    Image(systemName: "arrow.up.right")
                }
                .font(Tokens.TypeScale.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Color.accent)
        }
    }

    // MARK: Compatibility (§9)

    private var compatibilitySection: some View {
        let compat = compatibility
        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack {
                sectionTitle("Compatibility")
                Spacer(minLength: 0)
                CompatibilityBadge(verdict: compat.verdict)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(compat.checks) { check in
                    HStack(alignment: .top, spacing: Tokens.Space.x2) {
                        Image(systemName: check.passed ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(check.passed ? Tokens.Color.success : Tokens.Color.warn)
                            .frame(width: 14)
                            .padding(.top, 2)
                        Text(check.text)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(compat.summary)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            if compat.verdict == .needsMoreMemory || compat.verdict == .tight {
                // A warning, not a block (§9) — the user decides.
                HStack(spacing: Tokens.Space.x2) {
                    Button("Choose a smaller model") { onClose() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                    Button("Download anyway") { queue.enqueue(effectiveModel) }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.textSec)
                    Spacer(minLength: 0)
                }
            }
            if compat.diskIsCritical {
                InlineBanner(
                    kind: .error,
                    title: "Not enough disk space",
                    message: "\(model.resources.diskLabel) is needed and \(ModelStorageReport.label(compat.freeDiskBytes)) is free. Free up space before downloading.",
                    actionTitle: nil, action: nil
                )
            } else if !compat.hasEnoughDisk {
                InlineBanner(
                    kind: .warning,
                    title: "Disk space is tight",
                    message: "This download needs \(model.resources.diskLabel) and \(ModelStorageReport.label(compat.freeDiskBytes)) is free.",
                    actionTitle: nil, action: nil
                )
            }
            if compat.verdict.isBlocking, model.format != .coreML, model.format != .gguf {
                // §69: don't just hide it — say why, and say whether the same
                // repository ships something that would work.
                let hasAlternative = repoMetadata?.variants.contains(where: \.isSupported) == true
                InlineBanner(
                    kind: .info,
                    title: "Not currently supported",
                    message: ModelRuntimeRegistry.unsupportedReason(for: model.format)
                        + (hasAlternative
                           ? " This repository does ship a build NotchWhisper can run — see Builds in this repository below."
                           : "")
                )
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    // MARK: Performance (§14, §20, §40)

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack {
                sectionTitle("Performance")
                Spacer(minLength: 0)
                if benchmarks.result(for: model.id) == nil, lifecycle.isInstalled {
                    Button("Run benchmark") { actions.benchmark(model.id) }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                }
            }

            HStack(alignment: .top, spacing: Tokens.Space.x4) {
                ProvenanceMetric(label: "Accuracy", metric: model.accuracy)
                ProvenanceMetric(label: "Speed", metric: model.speed)
                MetricCell(label: "Languages", value: model.capabilities.languageCountLabel)
            }
            HStack(alignment: .top, spacing: Tokens.Space.x4) {
                MetricCell(label: "Parameters", value: model.resources.parameterCount ?? "—",
                           isUnknown: model.resources.parameterCount == nil)
                MetricCell(label: "Disk size", value: model.resources.diskLabel,
                           isUnknown: model.resources.diskBytes == 0)
                MetricCell(label: "Memory", value: model.resources.memoryLabel,
                           note: model.isBuiltIn ? nil : "Estimated from download size",
                           isUnknown: model.resources.memoryBytes == 0)
            }
            ProvenanceFootnote(metrics: [model.accuracy, model.speed])

            if let result = benchmarks.result(for: model.id) {
                Divider().overlay(Tokens.Color.hairline)
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    HStack {
                        Text("Measured on this Mac")
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.text)
                        Spacer(minLength: 0)
                        Text(ModelsView.relative(result.ranAt))
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    HStack(alignment: .top, spacing: Tokens.Space.x4) {
                        MetricCell(label: "Audio", value: "\(Int(result.audioSeconds)) s")
                        MetricCell(label: "Processing", value: result.processLabel)
                        MetricCell(label: "Real-time factor", value: result.rtfLabel)
                        MetricCell(label: "Peak memory", value: result.memoryLabel)
                    }
                    if let wer = result.werLabel {
                        MetricCell(label: "Word error rate", value: wer,
                                   note: "Against your reference transcript")
                    }
                    if !result.verdict.isEmpty {
                        Label(result.verdict, systemImage: "checkmark.seal.fill")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.success)
                    }
                }
                DisclosureSection("Performance inspector") {
                    VStack(alignment: .leading, spacing: 2) {
                        SpecLine(label: "Load time", value: result.loadLabel)
                        if let first = result.firstResultSeconds {
                            SpecLine(label: "First result", value: String(format: "%.2f s", first))
                        }
                        SpecLine(label: "Real-time factor", value: result.rtfLabel)
                        SpecLine(label: "Peak memory", value: result.memoryLabel)
                        SpecLine(label: "CPU (all cores)", value: result.cpuLabel)
                        SpecLine(label: "Acceleration",
                                 value: model.runtime.accelerators.joined(separator: ", "))
                        SpecLine(label: "Machine", value: result.machineSummary)
                    }
                }
            } else {
                Text(lifecycle.isInstalled
                     ? "Not benchmarked on this Mac."
                     : "Not benchmarked. Published figures come from the model card and are approximate.")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    // MARK: Capabilities (§67) + languages + privacy (§42)

    private var capabilitiesSection: some View {
        let caps = model.capabilities
        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Capabilities")
            VStack(alignment: .leading, spacing: 5) {
                capabilityLine("Speech to text", caps.speechToText)
                capabilityLine("Multilingual", caps.isMultilingual)
                capabilityLine("Live dictation (streaming)", caps.streaming)
                capabilityLine("Segment timestamps", caps.timestamps)
                capabilityLine("Word timestamps", caps.wordTimestamps)
                capabilityLine("Translation to English", caps.translation)
                capabilityLine("Speaker diarization", caps.diarization)
            }

            if !caps.languages.isEmpty {
                Divider().overlay(Tokens.Color.hairline)
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    HStack {
                        Text("Languages")
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.text)
                        Spacer(minLength: 0)
                        if let source = caps.languageSource {
                            Text(source)
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                    }
                    let prominent = caps.prominentLanguages
                    FlowLayout {
                        ForEach(prominent.prefix(12), id: \.self) { code in
                            CapabilityTag(text: ModelCapabilities.languageName(code))
                        }
                        if prominent.count > 12 {
                            Text("and \(prominent.count - 12) more")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                    }
                }
            }

            Divider().overlay(Tokens.Color.hairline)
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Color.success)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device")
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.text)
                    Text("NotchWhisper runs this model on your Mac. Audio and transcripts are never sent anywhere.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    private func capabilityLine(_ label: String, _ supported: Bool) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: supported ? "checkmark" : "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(supported ? Tokens.Color.success : Tokens.Color.textTert)
                .frame(width: 14)
            Text(label)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(supported ? Tokens.Color.textSec : Tokens.Color.textTert)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(supported ? "supported" : "not supported")")
    }

    // MARK: Variants (§17)

    @ViewBuilder
    private var variantsSection: some View {
        // Only for models found through discovery. Every built-in Whisper model
        // lives in the same repository as the other 26 catalog entries, so
        // listing "builds in this repository" there would just replay the
        // catalog inside one model's page (§74).
        if !model.isBuiltIn, let repo = repoMetadata, repo.variants.count > 1 {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                sectionTitle("Builds in this repository")
                Text("Pick the build that suits this Mac. Only formats NotchWhisper can run are selectable.")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)

                let recommended = recommendedVariant(in: repo)
                VStack(spacing: 0) {
                    ForEach(repo.variants) { variant in
                        variantRow(variant, isRecommended: variant.id == recommended?.id)
                        if variant.id != repo.variants.last?.id {
                            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                        }
                    }
                }
                if let recommended {
                    Label("Recommended: \(recommended.label) — best balance of quality and memory for this Mac.",
                          systemImage: "sparkles")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: nil, elevated: false)
        }
    }

    private func variantRow(_ variant: ModelVariant, isRecommended: Bool) -> some View {
        Button {
            guard variant.isSupported else { return }
            selectedVariantId = variant.id
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                Image(systemName: selectedVariantId == variant.id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(variant.isSupported
                                     ? (selectedVariantId == variant.id ? Tokens.Color.accent : Tokens.Color.textTert)
                                     : Tokens.Color.textTert.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(variant.label)
                            .font(Tokens.TypeScale.callout.weight(.medium))
                            .foregroundStyle(variant.isSupported ? Tokens.Color.text : Tokens.Color.textTert)
                        CapabilityTag(text: variant.format.displayName)
                        if isRecommended { AwardTag(award: .bestForYourMac) }
                    }
                    if let reason = variant.unsupportedReason {
                        Text(reason)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let group = variant.weightGroup {
                        Text("Model weights · \(group.count) files · \(ModelStorageReport.label(group.bytes))")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                Spacer(minLength: Tokens.Space.x3)
                Text(variant.sizeLabel)
                    .font(Tokens.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            .padding(.vertical, Tokens.Space.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!variant.isSupported)
        .accessibilityLabel("\(variant.label), \(variant.sizeLabel)\(variant.isSupported ? "" : ", not supported")")
    }

    /// Largest build that still fits this Mac comfortably.
    private func recommendedVariant(in repo: HFRepoMetadata) -> ModelVariant? {
        let supported = repo.variants.filter(\.isSupported)
        let budget = Int64(Double(hw.physicalMemory) * 0.55 / 1.5)
        return supported.filter { $0.sizeBytes <= budget }.max { $0.sizeBytes < $1.sizeBytes }
            ?? supported.min { $0.sizeBytes < $1.sizeBytes }
    }

    // MARK: Trust and licence (§29, §30, §71)

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Source and licence")
            ModelAttribution(
                org: model.providerHandle, display: model.provider,
                note: model.packagerNote, link: model.repositoryURL
            )
            HStack(spacing: Tokens.Space.x2) {
                ModelTrustBadge(trust: model.trust)
                Text(model.trust.explanation)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Divider().overlay(Tokens.Color.hairline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Licence")
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.text)
                if let license = model.license ?? repoMetadata?.license {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(license.uppercased())
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                        Button("View licence") {
                            NSWorkspace.shared.open(
                                model.repositoryURL.appendingPathComponent("blob/main/LICENSE"))
                        }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.accent)
                        Spacer(minLength: 0)
                    }
                    if Self.restrictiveLicenses.contains(license.lowercased()) {
                        Label("Licence restrictions may apply. Review the licence before using this model commercially.",
                              systemImage: "exclamationmark.triangle")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Licence information unavailable. Review the repository before using this model commercially.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if repoMetadata?.isGated == true {
                InlineBanner(
                    kind: .warning,
                    title: "Access required",
                    message: "This repository is gated on Hugging Face. Request access there, then add your token in Settings.",
                    actionTitle: "Open repository",
                    action: { NSWorkspace.shared.open(model.repositoryURL) }
                )
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    private static let restrictiveLicenses: Set<String> = [
        "cc-by-nc-4.0", "cc-by-nc-sa-4.0", "cc-by-nc-nd-4.0", "other", "unknown",
        "llama2", "llama3", "llama3.1", "gemma", "openrail", "bigscience-openrail-m",
    ]

    // MARK: Usage (§41)

    @ViewBuilder
    private var usageSection: some View {
        if let stats = benchmarks.stats(for: model.id), stats.sessions > 0 {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                sectionTitle("Usage on this Mac")
                HStack(alignment: .top, spacing: Tokens.Space.x4) {
                    MetricCell(label: "Transcribed", value: stats.transcribedLabel)
                    MetricCell(label: "Sessions", value: "\(stats.sessions)")
                    MetricCell(label: "Average processing",
                               value: String(format: "%.1f s", stats.averageProcessingSeconds))
                    MetricCell(label: "Average RTF",
                               value: stats.averageRTF.map { String(format: "%.2f×", $0) } ?? "—",
                               isUnknown: stats.averageRTF == nil)
                }
                HStack(alignment: .top, spacing: Tokens.Space.x4) {
                    MetricCell(label: "Failures", value: "\(stats.failures)")
                    MetricCell(label: "Last used",
                               value: stats.lastUsed.map(ModelsView.relative) ?? "Never",
                               isUnknown: stats.lastUsed == nil)
                    if stats.peakFootprintBytes > 0 {
                        MetricCell(label: "Peak memory",
                                   value: ModelStorageReport.label(stats.peakFootprintBytes))
                    }
                }
                Text("Stored on this Mac only. Nothing about your audio or transcripts is recorded.")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: nil, elevated: false)
        }
    }

    // MARK: Files (§16)

    @ViewBuilder
    private var filesSection: some View {
        if let repo = repoMetadata, !repo.files.isEmpty,
           let files = scopedFiles(in: repo) {
            let weights = files.filter(\.isWeightFile)
            let others = files.filter { !$0.isWeightFile }
            DisclosureSection("Files", subtitle: "\(files.count) files · \(ModelStorageReport.label(files.reduce(0) { $0 + $1.sizeBytes }))") {
                VStack(alignment: .leading, spacing: 3) {
                    // Sharded weights read as one logical group, not N rows.
                    if weights.count > 1 {
                        fileLine("Model weights",
                                 "\(weights.count) files · \(ModelStorageReport.label(weights.reduce(0) { $0 + $1.sizeBytes }))",
                                 emphasised: true)
                    } else if let single = weights.first {
                        fileLine(single.fileName, single.sizeLabel, emphasised: true)
                    }
                    ForEach(others.prefix(14)) { file in
                        fileLine(file.fileName, file.sizeLabel)
                    }
                    if others.count > 14 {
                        Text("and \(others.count - 14) more support files")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    Divider().overlay(Tokens.Color.hairline).padding(.vertical, 2)
                    fileLine("Total",
                             ModelStorageReport.label(files.reduce(0) { $0 + $1.sizeBytes }),
                             emphasised: true)
                }
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: nil, elevated: false)
        }
    }

    /// Files belonging to *this model*, or nil when they can't be isolated.
    ///
    /// Returning the whole repository would be a file browser, not a model's
    /// file list — so when the model's own files can't be identified, the
    /// section is simply not shown.
    private func scopedFiles(in repo: HFRepoMetadata) -> [HFFileEntry]? {
        if let folder = model.folderName {
            let scoped = repo.files.filter { $0.path.hasPrefix(folder + "/") }
            return scoped.isEmpty ? nil : scoped
        }
        if let selectedVariantId,
           let variant = repo.variants.first(where: { $0.id == selectedVariantId }) {
            return variant.files
        }
        // A single-build repository is unambiguous; anything else isn't.
        return repo.variants.count == 1 ? repo.variants[0].files : nil
    }

    private func fileLine(_ name: String, _ size: String, emphasised: Bool = false) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Tokens.Color.success.opacity(emphasised ? 1 : 0.5))
                .frame(width: 12)
            Text(name)
                .font(emphasised ? Tokens.TypeScale.captionSB : Tokens.TypeScale.caption)
                .foregroundStyle(emphasised ? Tokens.Color.text : Tokens.Color.textSec)
                .lineLimit(1)
            Spacer(minLength: Tokens.Space.x3)
            Text(size)
                .font(Tokens.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.textTert)
        }
    }

    // MARK: Version / pinning (§32)

    @ViewBuilder
    private var versionSection: some View {
        if lifecycle.isInstalled {
            DisclosureSection("Version") {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    Picker("", selection: $pinRevision) {
                        Text("Latest compatible").tag(false)
                        Text("Pin revision").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: pinRevision) { _, pinned in
                        registry.pin(model.id, revision: pinned
                            ? (revisionText.nilIfEmpty ?? installation?.commitSha
                               ?? repoMetadata?.sha ?? "")
                            : nil)
                    }
                    if pinRevision {
                        TextField("Commit SHA", text: $revisionText)
                            .textFieldStyle(.roundedBorder)
                            .font(Tokens.TypeScale.bodyMono)
                            .frame(maxWidth: 340)
                            .onSubmit { registry.pin(model.id, revision: revisionText) }
                        Text("Pinning keeps this model on one revision, so an upstream change can't alter a production workflow.")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pinned = registry.pinnedRevision(model.id) {
                        HStack(spacing: 5) {
                            Image(systemName: "pin.fill").font(.system(size: 9))
                            Text("Pinned to \(String(pinned.prefix(12)))")
                                .font(Tokens.TypeScale.micro)
                        }
                        .foregroundStyle(Tokens.Color.warn)
                    }
                }
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: nil, elevated: false)
        }
    }

    // MARK: Advanced (§65)

    private var advancedSection: some View {
        DisclosureSection("Advanced") {
            VStack(alignment: .leading, spacing: 2) {
                SpecLine(label: "Model identifier", value: model.id, monospaced: true, copyable: true)
                SpecLine(label: "Repository", value: model.repositoryId, monospaced: true, copyable: true)
                SpecLine(label: "Revision",
                         value: registry.pinnedRevision(model.id) ?? repoMetadata?.sha ?? "Default branch",
                         monospaced: true, copyable: repoMetadata?.sha != nil)
                if let sha = installation?.commitSha {
                    SpecLine(label: "Installed commit", value: sha, monospaced: true, copyable: true)
                }
                SpecLine(label: "Runtime", value: model.runtime.engine.detailName)
                SpecLine(label: "File format", value: model.format.displayName)
                SpecLine(label: "Quantization", value: model.resources.quantization ?? "Full precision")
                SpecLine(label: "Acceleration", value: model.runtime.accelerators.joined(separator: ", "))
                SpecLine(label: "Minimum OS", value: model.runtime.minimumOS)
                SpecLine(label: "Loader", value: model.runtime.loaderDescription)
                SpecLine(label: "Repository code",
                         value: model.runtime.executesRepositoryCode
                            ? "Executed" : "Never executed")
                if let library = repoMetadata?.libraryName {
                    SpecLine(label: "Library", value: library)
                }
                if let pipeline = repoMetadata?.pipelineTag {
                    SpecLine(label: "Pipeline", value: pipeline)
                }
                if let repo = repoMetadata {
                    SpecLine(label: "Downloads", value: repo.downloads.formatted())
                    SpecLine(label: "Last updated", value: repo.lastModifiedLabel)
                }
                if let install = installation {
                    SpecLine(label: "Local path", value: install.installedPath,
                             monospaced: true, copyable: true)
                    SpecLine(label: "Installed", value: ModelsView.relative(install.installedAt))
                    SpecLine(label: "Verification", value: verificationLabel(install.verification))
                    SpecLine(label: "On disk", value: ModelStorageReport.label(install.sizeBytes))
                }
                if let error = metadata.error(for: model.repositoryId) {
                    SpecLine(label: "Metadata", value: "Couldn't refresh — \(error)")
                }
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    private func verificationLabel(_ verification: ModelInstallation.Verification) -> String {
        switch verification {
        case .verified:   return "Files verified after install"
        case .unverified: return "Not verified"
        case .failed:     return "Verification failed — repair needed"
        }
    }

    // MARK: Shared

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Tokens.TypeScale.headline)
            .foregroundStyle(Tokens.Color.text)
            .accessibilityAddTraits(.isHeader)
    }
}
