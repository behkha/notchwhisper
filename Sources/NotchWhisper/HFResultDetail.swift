import SwiftUI
import AppKit

private extension ComparisonResult {
    var isEqualResult: Bool { self == .orderedSame }
}

// MARK: - Expanded result panel
//
// Everything the Hub returned about a repository, plus the builds this app can
// actually install. The file list is fetched here and nowhere earlier: a search
// that eagerly fetched 30 file listings would be slow and rude to the Hub (§77).

struct HFResultDetail: View {
    let model: HFHubModel
    let actions: ModelActions
    let onOpenDetails: (ModelDescriptor) -> Void

    @ObservedObject private var cache = HFMetadataCache.shared
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var queue = ModelDownloadQueue.shared

    @State private var repo: HFRepoMetadata?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            buildsSection
            overviewSection
            if !model.languages.isEmpty { languagesSection }
            if !model.evals.isEmpty { benchmarksSection }
            if !model.baseModels.isEmpty { lineageSection }
            if !model.tags.isEmpty { tagsSection }
            if !model.inferenceProviders.isEmpty { providersSection }
        }
        .padding(.top, Tokens.Space.x2)
        .task(id: model.repoId) { await loadFiles() }
    }

    // MARK: Builds

    @ViewBuilder
    private var buildsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Installable builds", count: repo.map { repo in
                let supported = repo.variants.filter(\.isSupported).count
                return supported == 1 ? "1 build" : "\(supported) builds"
            })

            if isLoading {
                HStack(spacing: Tokens.Space.x2) {
                    ProgressView().controlSize(.small)
                    Text("Reading the repository's file list…")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                .padding(.vertical, Tokens.Space.x2)
            } else if let error {
                InlineBanner(kind: model.isGated ? .warning : .error,
                             title: model.isGated ? "This repository is gated" : "Couldn't read the file list",
                             message: error,
                             actionTitle: "Open on Hugging Face",
                             action: { NSWorkspace.shared.open(model.repositoryURL) })
            } else if let repo {
                let variants = repo.variants
                if variants.isEmpty {
                    InlineBanner(kind: .info,
                                 title: "Nothing installable in this repository",
                                 message: model.installability.reason
                                    ?? ModelRuntimeRegistry.unsupportedReason(for: repo.detectedFormat),
                                 actionTitle: "Open on Hugging Face",
                                 action: { NSWorkspace.shared.open(model.repositoryURL) })
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                            if index > 0 { Divider().overlay(Tokens.Color.hairline) }
                            buildRow(variant, in: repo)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.Color.fillQuieter))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private func buildRow(_ variant: ModelVariant, in repo: HFRepoMetadata) -> some View {
        let descriptor = ModelCatalogService.descriptor(forVariant: variant, in: repo)
        let lifecycle = registry.lifecycle(of: descriptor.id)
        let compatibility = ModelCompatibility.verdict(for: descriptor, hw: .current)

        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(alignment: .center, spacing: Tokens.Space.x3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(variant.label)
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(variant.isSupported ? Tokens.Color.text : Tokens.Color.textTert)
                        // An unquantized GGUF is labelled "GGUF" already, so
                        // the format tag would just repeat the name.
                        if !variant.label.caseInsensitiveCompare(variant.format.displayName)
                            .isEqualResult {
                            Text(variant.format.displayName)
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        if variant.isSupported {
                            CompatibilityBadge(verdict: compatibility)
                        }
                    }
                    HStack(spacing: Tokens.Space.x3) {
                        Text(variant.sizeLabel)
                            .font(Tokens.TypeScale.micro.monospacedDigit())
                            .foregroundStyle(Tokens.Color.textTert)
                        if let group = variant.weightGroup {
                            Text("\(group.count) weight files")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        if let quant = variant.quantization,
                           !quant.caseInsensitiveCompare(variant.label).isEqualResult {
                            Text(quant)
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                    }
                    if let reason = variant.unsupportedReason {
                        Text(reason)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Tokens.Space.x2)
                if variant.isSupported {
                    ModelPrimaryButton(model: descriptor, lifecycle: lifecycle, actions: actions)
                    Button("Details") { onOpenDetails(descriptor) }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.textSec)
                }
            }
            if let job = queue.job(for: descriptor.id), job.state != .finished {
                DownloadProgressPanel(
                    job: job,
                    onPause: { actions.pause(descriptor.id) },
                    onResume: { actions.resume(descriptor.id) },
                    onCancel: { actions.cancel(descriptor.id) },
                    onRetry: { actions.retry(descriptor.id) }
                )
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, Tokens.Space.x3)
    }

    // MARK: Overview

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Repository")
            VStack(alignment: .leading, spacing: 0) {
                SpecLine(label: "Identifier", value: model.repoId, monospaced: true, copyable: true)
                SpecLine(label: "Publisher", value: model.author)
                if let task = model.pipelineTag {
                    SpecLine(label: "Task", value: HFHub.tasks.first { $0.id == task }?.label ?? task)
                }
                SpecLine(label: "Library", value: model.libraryName ?? "Not declared")
                SpecLine(label: "Licence", value: model.license?.uppercased() ?? "Not declared")
                SpecLine(label: "Weight format", value: model.installability.format.displayName)
                if let params = model.parameterLabel {
                    SpecLine(label: "Parameters", value: params)
                }
                if !model.precisions.isEmpty {
                    SpecLine(label: "Precision", value: precisionLabel)
                }
                if let repo, repo.totalBytes > 0 {
                    SpecLine(label: "Repository size",
                             value: ByteCountFormatter.string(fromByteCount: repo.totalBytes, countStyle: .file))
                } else if let size = model.sizeLabel {
                    SpecLine(label: "Weights size", value: size)
                }
                SpecLine(label: "Revision", value: model.shortSha ?? "—",
                         monospaced: true, copyable: model.sha != nil)
                SpecLine(label: "First published", value: HFHub.exact(model.createdAt))
                SpecLine(label: "Last updated",
                         value: "\(HFHub.exact(model.lastModified)) (\(model.updatedLabel))")
                SpecLine(label: "Access",
                         value: model.isGated
                            ? (model.gatedKind == "manual"
                               ? "Gated — the publisher approves each request"
                               : "Gated — accept the terms on Hugging Face")
                            : "Public")
                SpecLine(label: "Downloads",
                         value: "\(model.downloads30d.formatted()) in 30 days · \(model.downloadsAllTime.formatted()) all time")
                SpecLine(label: "Likes", value: model.likes.formatted())
                SpecLine(label: "Trending score", value: model.trendingScore > 0
                         ? String(model.trendingScore) : "Not trending")
                if let repo, !repo.files.isEmpty {
                    SpecLine(label: "Files", value: "\(repo.files.count) in the repository")
                }
            }
        }
    }

    private var precisionLabel: String {
        model.precisions
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \(HFHub.compact(Int($0.value)))" }
            .joined(separator: ", ")
    }

    // MARK: Languages / tags / lineage

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Languages", count: "\(model.languages.count)")
            FlowLayout(spacing: 6) {
                ForEach(model.languages.prefix(60), id: \.self) { code in
                    Text(ModelCapabilities.languageName(code))
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textSec)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Tokens.Color.fillQuiet))
                }
                if model.languages.count > 60 {
                    Text("+\(model.languages.count - 60) more")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Tags", count: "\(model.tags.count)")
            FlowLayout(spacing: 6) {
                ForEach(model.tags.prefix(40), id: \.self) { tag in
                    Text(tag)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                }
            }
        }
    }

    private var lineageSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Lineage",
                               count: model.baseModelRelation.map { $0.capitalized })
            ForEach(model.baseModels, id: \.self) { base in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.Color.textTert)
                    Text(model.baseModelRelation.map { "\($0.capitalized) of" } ?? "Based on")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                    Link(base, destination: URL(string: "https://huggingface.co/\(base)")!)
                        .font(Tokens.TypeScale.micro.weight(.semibold))
                        .foregroundStyle(Tokens.Color.accent)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Benchmarks

    private var benchmarksSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Published benchmarks", count: "\(model.evals.count)")
            Text("Numbers the publisher reported. NotchWhisper hasn't measured them — run its own benchmark once the model is installed.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(model.evals.prefix(12).enumerated()), id: \.element.id) { index, eval in
                    if index > 0 { Divider().overlay(Tokens.Color.hairline) }
                    HStack(spacing: Tokens.Space.x3) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(eval.metricLabel)
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textSec)
                            Text(eval.datasetLabel)
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        Spacer(minLength: Tokens.Space.x3)
                        if eval.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Tokens.Color.success)
                                .help("Verified by Hugging Face")
                        }
                        Text(eval.valueLabel)
                            .font(Tokens.TypeScale.captionSB.monospacedDigit())
                            .foregroundStyle(Tokens.Color.text)
                    }
                    .padding(.horizontal, Tokens.Space.x3)
                    .padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Color.fillQuieter))
            if model.evals.count > 12 {
                Text("+\(model.evals.count - 12) more on the model card")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    // MARK: Inference providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            ModelSectionHeader("Hosted inference", count: "\(model.inferenceProviders.count)")
            Text("Providers Hugging Face lists for this model. NotchWhisper never sends your audio to any of them — everything runs on this Mac.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(model.inferenceProviders) { provider in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(provider.isLive ? Tokens.Color.success : Tokens.Color.textTert)
                            .frame(width: 5, height: 5)
                        Text(provider.provider)
                            .font(Tokens.TypeScale.micro)
                    }
                    .foregroundStyle(Tokens.Color.textTert)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Tokens.Color.fillQuiet))
                    .help("\(provider.provider): \(provider.status)")
                }
            }
        }
    }

    // MARK: Loading

    private func loadFiles() async {
        if let cached = cache.cached(model.repoId) {
            repo = cached
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { repo = try await cache.fetch(model.repoId) }
        catch { self.error = error.localizedDescription }
    }
}
