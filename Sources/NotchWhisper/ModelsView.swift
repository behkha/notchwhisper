import SwiftUI
import AppKit

// MARK: - Discovery filters
//
// §12: combinable, compact, and driven by real model metadata rather than a
// hardcoded list in the view.

struct DiscoveryFilters: Equatable {
    enum SizeBucket: String, CaseIterable, Identifiable {
        case underHalfGB, halfToOne, oneToTwo, twoToFive, overFive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .underHalfGB: return "Under 500 MB"
            case .halfToOne:   return "500 MB – 1 GB"
            case .oneToTwo:    return "1 – 2 GB"
            case .twoToFive:   return "2 – 5 GB"
            case .overFive:    return "Over 5 GB"
            }
        }
        func contains(_ bytes: Int64) -> Bool {
            let mb = Double(bytes) / 1_048_576
            switch self {
            case .underHalfGB: return mb < 500
            case .halfToOne:   return mb >= 500 && mb < 1024
            case .oneToTwo:    return mb >= 1024 && mb < 2048
            case .twoToFive:   return mb >= 2048 && mb < 5120
            case .overFive:    return mb >= 5120
            }
        }
    }

    enum Performance: String, CaseIterable, Identifiable {
        case fast, balanced, accurate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fast:     return "Fast"
            case .balanced: return "Balanced"
            case .accurate: return "Accurate"
            }
        }
    }

    enum CompatibilityFilter: String, CaseIterable, Identifiable {
        case compatible, needsMemory, unsupported
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compatible:  return "Compatible"
            case .needsMemory: return "Requires more RAM"
            case .unsupported: return "Unsupported"
            }
        }
    }

    var language: String?
    var size: SizeBucket?
    var performance: Performance?
    var format: ModelFileFormat?
    var engine: ModelEngine?
    var trust: ModelTrust?
    var compatibility: CompatibilityFilter?

    var isEmpty: Bool {
        language == nil && size == nil && performance == nil && format == nil
            && engine == nil && trust == nil && compatibility == nil
    }

    mutating func clear() { self = DiscoveryFilters() }

    /// Does a model survive every active filter?
    func matches(_ model: ModelDescriptor, compatibility verdict: ModelCompatibility.Verdict) -> Bool {
        if let language, !model.capabilities.supports(languageCode: language) { return false }
        if let size {
            guard model.resources.diskBytes > 0, size.contains(model.resources.diskBytes) else { return false }
        }
        if let performance {
            guard let speed = model.speed.fraction else { return false }
            switch performance {
            case .fast:     guard speed >= 0.65 else { return false }
            case .balanced: guard speed >= 0.3 && speed < 0.65 else { return false }
            case .accurate: guard speed < 0.3 else { return false }
            }
        }
        if let format, model.format != format { return false }
        if let engine, model.engine != engine { return false }
        if let trust, model.trust != trust { return false }
        if let compatibility {
            switch compatibility {
            case .compatible:  guard verdict <= .tight else { return false }
            case .needsMemory: guard verdict == .needsMoreMemory else { return false }
            case .unsupported: guard verdict == .unsupported else { return false }
            }
        }
        return true
    }
}

/// Ordering for discovery results (§53).
enum ModelSortOrder: String, CaseIterable, Identifiable {
    case recommended, quality, speed, size, popularity, recentlyUpdated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recommended:     return "Recommended"
        case .quality:         return "Quality"
        case .speed:           return "Speed"
        case .size:            return "Size"
        case .popularity:      return "Popularity"
        case .recentlyUpdated: return "Recently updated"
        }
    }
}

// MARK: - Sheets

enum ModelsRoute: Identifiable, Equatable {
    case test(String)
    case benchmark(String)
    case compare([String])
    case importModel
    case storage
    case downloads
    case pasteURL

    var id: String {
        switch self {
        case .test(let id):      return "test-\(id)"
        case .benchmark(let id): return "bench-\(id)"
        case .compare(let ids):  return "compare-\(ids.joined(separator: ","))"
        case .importModel:       return "import"
        case .storage:           return "storage"
        case .downloads:         return "downloads"
        case .pasteURL:          return "paste"
        }
    }
}

// MARK: - Models page

/// Model Hub + Model Manager.
///
/// The page answers three questions in order: what engine is running, what is
/// installed, and what else could I be using. Everything technical lives one
/// level down, in the detail view.
struct ModelsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var queue = ModelDownloadQueue.shared
    @ObservedObject private var benchmarks = ModelBenchmarkService.shared
    @ObservedObject private var metadata = HFMetadataCache.shared
    @ObservedObject private var importer = ModelImporter.shared
    @ObservedObject private var storageLocation = ModelStorageLocation.shared
    @ObservedObject private var catalog = ModelCatalog.shared

    // Navigation
    @State private var detailModel: ModelDescriptor?
    @State private var route: ModelsRoute?
    @State private var removalTarget: ModelDescriptor?
    @State private var removalRefusal: String?

    // Discovery
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var remoteResults: [ModelDescriptor] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var filters = DiscoveryFilters()
    @State private var sort: ModelSortOrder = .recommended
    @State private var showAllDiscover = false
    /// Bumped by "Browse Models" so the scroll reader can jump to Discover. The
    /// section is already on the page, so without this the button looks dead.
    @State private var browseRequests = 0

    // Storage
    @State private var storageReport = ModelStorageReport()

    // Interaction
    @FocusState private var searchFocused: Bool
    @State private var selectedInstalledId: String?
    @State private var isDropTargeted = false

    private let hw = HardwareInfo.current

    var body: some View {
        ZStack {
            if !registry.hasScanned {
                loadingSkeleton
            } else if registry.installedIds.isEmpty && queue.activeJobs.isEmpty {
                firstRunView
            } else {
                mainScroll
            }
            if isDropTargeted { dropOverlay }
        }
        .background(keyboardShortcuts)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { importer.handleDrop($0) }
        .onChange(of: importer.candidate?.id) { _, new in if new != nil { route = .importModel } }
        .onChange(of: query) { _, new in debounceSearch(new) }
        .onChange(of: registry.installedIds) { _, _ in Task { await refreshStorage() } }
        .onChange(of: settings.modelId) { _, _ in Task { await refreshStorage() } }
        .task {
            catalog.refreshIfNeeded()
            await registry.scan()
            await refreshStorage()
            prefetchActiveMetadata()
        }
        // Detail lives in a sheet at every width, so a narrow window never has
        // to scroll sideways to reach it (§55).
        .sheet(item: $detailModel) { model in
            ModelDetailSheet(model: model, actions: actions) { detailModel = nil }
                .environmentObject(state)
                .environmentObject(settings)
        }
        .sheet(item: $route) { route in
            routeSheet(route)
                .environmentObject(state)
                .environmentObject(settings)
        }
        .confirmationDialog(
            removalTarget.map { "Remove \($0.displayName)?" } ?? "Remove model?",
            isPresented: Binding(get: { removalTarget != nil },
                                 set: { if !$0 { removalTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = removalTarget {
                Button("Remove model", role: .destructive) { performRemove(target) }
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: {
            if let target = removalTarget {
                Text(removalMessage(target))
            }
        }
        .alert("Can't remove this model", isPresented: Binding(
            get: { removalRefusal != nil }, set: { if !$0 { removalRefusal = nil } }
        )) {
            Button("OK", role: .cancel) { removalRefusal = nil }
        } message: {
            Text(removalRefusal ?? "")
        }
    }

    // MARK: Main scroll

    private var mainScroll: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                    header
                    banners
                    activeSection
                    recentlyUsedStrip
                    installedSection
                    recommendedSection
                    discoverSection.id(Self.discoverAnchor)
                    storageSection
                }
                .padding(Tokens.Space.x8)
                .frame(maxWidth: 1040, alignment: .leading)
                .frame(maxWidth: .infinity)
                .onChange(of: browseRequests) { _, _ in
                    withAnimation(Tokens.Motion.ease(reduceMotion: Tokens.A11y.reduceMotion)) {
                        proxy.scrollTo(Self.discoverAnchor, anchor: .top)
                    }
                    searchFocused = true
                }
            }
        }
        .scrollIndicators(.never)
    }

    private static let discoverAnchor = "discover-section"

    // MARK: Header (§4)

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.x4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models")
                        .font(Tokens.TypeScale.largeTitle)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Manage the speech recognition engines installed on your Mac.")
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: Tokens.Space.x4)
                HStack(spacing: Tokens.Space.x2) {
                    // At a narrow window width the labels are dropped rather
                    // than wrapped; the tooltips and VoiceOver labels stay.
                    ViewThatFits(in: .horizontal) {
                        headerActions(iconOnly: false)
                        headerActions(iconOnly: true)
                    }
                    Menu {
                        Button("Model storage…") { route = .storage }
                        Button("Compare models…") { openCompare() }
                        Divider()
                        Button("Search Hugging Face…") { openHubBrowser() }
                        Button("Add from Hugging Face URL…") { route = .pasteURL }
                        Button("Reveal models folder") { storageLocation.revealInFinder() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.Color.textSec)
                            .frame(width: 30, height: 26)
                            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More model options")
                }
            }

            HStack(spacing: Tokens.Space.x3) {
                Label(hw.summary, systemImage: hw.isAppleSilicon ? "memorychip" : "cpu")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                if let freshness = metadata.freshnessLabel, metadata.isOnline {
                    Text("·").foregroundStyle(Tokens.Color.textTert)
                    Text(freshness)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The header's action cluster, in full-label and icon-only forms.
    @ViewBuilder
    private func headerActions(iconOnly: Bool) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            if queue.activeCount > 0 {
                ToolbarIconButton(icon: "arrow.down.circle", label: "Downloads",
                                  badge: queue.activeCount, iconOnly: iconOnly) { route = .downloads }
            }
            ToolbarIconButton(icon: "arrow.clockwise", label: "Refresh",
                              iconOnly: iconOnly) { refreshAll() }
            ToolbarIconButton(icon: "square.and.arrow.down", label: "Import Model",
                              iconOnly: iconOnly) { importer.presentOpenPanel() }
            ToolbarIconButton(icon: "magnifyingglass", label: "Browse Models",
                              iconOnly: iconOnly) {
                showAllDiscover = true
                browseRequests += 1
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: Tokens.Space.x2) {
            if !metadata.isOnline {
                InlineBanner(
                    kind: .info,
                    title: "You're offline",
                    message: "Your installed models still work, and benchmarks and testing are unaffected. New downloads resume when you reconnect.",
                    actionTitle: "Retry",
                    action: { refreshAll() }
                )
            }
            if let completed = queue.lastCompleted,
               registry.installedIds.contains(completed.id) {
                InlineBanner(
                    kind: .success,
                    title: "\(completed.name) is ready",
                    message: completed.id == registry.activeId
                        ? "It's now your active model." : nil,
                    actionTitle: completed.id == registry.activeId ? "Dismiss" : "Use this model",
                    action: {
                        if completed.id == registry.activeId { queue.dismissFinished() }
                        else { actions.activate(completed.id) }
                    },
                    secondaryTitle: completed.id == registry.activeId ? nil : "Dismiss",
                    secondaryAction: completed.id == registry.activeId ? nil : { queue.dismissFinished() }
                )
            }
            if let advice = batteryAdvice {
                InlineBanner(
                    kind: .info,
                    title: "Running on battery",
                    message: advice.text,
                    actionTitle: "Use \(advice.model.displayName)",
                    action: { actions.activate(advice.model.id) }
                )
            }
            if storageReport.freeBytes > 0, storageReport.freeBytes < 6_000_000_000 {
                InlineBanner(
                    kind: storageReport.freeBytes < 2_000_000_000 ? .error : .warning,
                    title: storageReport.freeBytes < 2_000_000_000 ? "Not enough disk space" : "Low disk space",
                    message: "\(ModelStorageReport.label(storageReport.freeBytes)) available. Larger models need several gigabytes.",
                    actionTitle: "Manage storage",
                    action: { route = .storage }
                )
            }
            if let error = importer.error {
                InlineBanner(
                    kind: .error, title: "Couldn't import that model", message: error,
                    actionTitle: "Dismiss", action: { importer.error = nil }
                )
            }
        }
    }

    private var batteryAdvice: (model: ModelDescriptor, text: String)? {
        ModelRecommender.batteryAdvice(
            active: registry.descriptor(for: registry.activeId),
            installed: registry.installedDescriptors
        )
    }

    // MARK: Active model (§5)

    private var activeSection: some View {
        let model = registry.descriptor(for: registry.activeId)
        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            ModelSectionHeader("Active model") {
                if registry.defaultId != registry.activeId {
                    Button("Set as default") { registry.defaultId = registry.activeId }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                        .help("The model each new dictation starts with.")
                }
            }
            ActiveModelPanel(
                model: model,
                lifecycle: registry.lifecycle(of: model.id),
                compatibility: ModelCompatibility.evaluate(model, hw: hw),
                actions: actions
            )
        }
    }

    // MARK: Recently used (§36 — subtle, never competing with Active)

    @ViewBuilder
    private var recentlyUsedStrip: some View {
        let recent = registry.recentlyUsed(limit: 3)
        if !recent.isEmpty {
            HStack(spacing: Tokens.Space.x3) {
                Text("Recently used")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
                ForEach(recent, id: \.0.id) { model, date in
                    Button { actions.activate(model.id) } label: {
                        HStack(spacing: 5) {
                            Text(model.displayName).font(Tokens.TypeScale.micro.weight(.medium))
                            Text(Self.relative(date)).font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        .foregroundStyle(Tokens.Color.textSec)
                        .padding(.horizontal, Tokens.Space.x2)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Tokens.Color.fillQuieter))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(Pressable(scale: 0.97))
                    .help("Switch to \(model.displayName)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Installed (§6)

    private var installedSection: some View {
        let installed = registry.installedDescriptors
        let corrupted = registry.corruptedIds.subtracting(registry.installedIds)
            .map { registry.descriptor(for: $0) }
        let all = installed + corrupted

        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            ModelSectionHeader("Installed", count: countLabel(all.count, "model")) {
                if installed.count >= 2 {
                    Button("Compare") { openCompare() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                }
            }

            VStack(spacing: 0) {
                if registry.isScanning && all.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in ModelRowSkeleton() }
                } else {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, model in
                        InstalledModelRow(
                            model: model,
                            lifecycle: registry.lifecycle(of: model.id),
                            actions: actions,
                            isSelected: selectedInstalledId == model.id
                        )
                        if index < all.count - 1 {
                            Rectangle().fill(Tokens.Color.hairline)
                                .frame(height: 1).padding(.horizontal, Tokens.Space.x3)
                        }
                    }
                }
            }
            .padding(.vertical, Tokens.Space.x1)
            .card(padding: nil, elevated: false)
            // Arrow keys move the selection, Return activates, Delete removes.
            .focusable()
            .onMoveCommand { direction in moveSelection(direction, in: all) }
            .onKeyPress(.return) {
                guard let id = selectedInstalledId else { return .ignored }
                actions.activate(id)
                return .handled
            }
            .onKeyPress(.delete) {
                guard let id = selectedInstalledId else { return .ignored }
                actions.requestRemove(registry.descriptor(for: id))
                return .handled
            }
            .onKeyPress(.space) {
                guard let id = selectedInstalledId else { return .ignored }
                detailModel = registry.descriptor(for: id)
                return .handled
            }
            .accessibilityLabel("Installed models")
        }
    }

    // MARK: Recommended (§10, §18)

    @ViewBuilder
    private var recommendedSection: some View {
        let candidates = ModelCatalogService.builtIn + remoteResults
        let recommendations = ModelRecommender.awards(from: candidates, hw: hw)
            .filter { registry.lifecycle(of: $0.model.id) != .active }
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                ModelSectionHeader("Recommended for your Mac") {
                    if let summary = LanguageProfile.shared.summary {
                        Text("Optimized for \(summary)")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Tokens.Space.x3) {
                        ForEach(recommendations) { rec in
                            RecommendationCard(
                                recommendation: rec,
                                lifecycle: registry.lifecycle(of: rec.model.id),
                                actions: actions
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Discover (§10–§13)

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            ModelSectionHeader("Discover models", count: discoverCountLabel) {
                Button {
                    openHubBrowser()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 10, weight: .semibold))
                        Text("Search Hugging Face").font(Tokens.TypeScale.micro.weight(.semibold))
                    }
                    .foregroundStyle(Tokens.Color.accent)
                    .padding(.horizontal, Tokens.Space.x2)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .accessibilityLabel("Search all of Hugging Face")

                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(ModelSortOrder.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sort: \(sort.label)").font(Tokens.TypeScale.micro)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Tokens.Color.textSec)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            searchBar
            hubHandoff
            filterBar
            activeFilterChips

            if let searchError {
                InlineBanner(
                    kind: .warning,
                    title: "Couldn't search Hugging Face",
                    message: searchError + " Built-in models are still listed below.",
                    actionTitle: "Retry",
                    action: { runRemoteSearch(debouncedQuery) }
                )
            }

            let results = discoverResults
            if results.isEmpty {
                discoverEmptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: Tokens.Space.x3)],
                    spacing: Tokens.Space.x3
                ) {
                    ForEach(results) { model in
                        DiscoverModelCard(
                            model: model,
                            lifecycle: registry.lifecycle(of: model.id),
                            compatibility: ModelCompatibility.evaluate(model, hw: hw),
                            award: nil,
                            actions: actions
                        )
                    }
                }
                if isSearching {
                    HStack(spacing: Tokens.Space.x2) {
                        ProgressView().controlSize(.small)
                        Text("Searching Hugging Face…")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                if !showAllDiscover, hiddenDiscoverCount > 0 {
                    Button("Browse all \(allDiscoverCandidates.count) models") {
                        withAnimation(Tokens.Motion.ease(reduceMotion: Tokens.A11y.reduceMotion)) {
                            showAllDiscover = true
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Color.textTert)
            TextField("Search models, providers, languages or repositories", text: $query)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
                .focused($searchFocused)
                .onSubmit { runRemoteSearch(query) }
                .accessibilityLabel("Search models")
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = ""; remoteResults = []; searchError = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Color.textTert)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, 9)
        .background(Tokens.Color.fillQuiet, in: Capsule())
        .overlay(Capsule().strokeBorder(
            searchFocused ? Tokens.Color.accent.opacity(0.5) : Tokens.Color.hairline, lineWidth: 1))
    }

    /// The bridge out of the page's local search and into the whole Hub. The
    /// catalogue here is curated and small; the Hub has thousands of models,
    /// and the user should never have to guess that.
    @ViewBuilder
    private var hubHandoff: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        Button { openHubBrowser() } label: {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accent)
                Text(trimmed.isEmpty
                     ? "Browse every speech model on Hugging Face"
                     : "Search Hugging Face for “\(trimmed)”")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                Text("⇧⌘F")
                    .font(Tokens.TypeScale.micro.monospacedDigit())
                    .foregroundStyle(Tokens.Color.textTert)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.Color.textTert)
            }
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Color.accent.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.Color.accent.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.995))
        .accessibilityLabel(trimmed.isEmpty
                            ? "Browse Hugging Face"
                            : "Search Hugging Face for \(trimmed)")
    }

    private var filterBar: some View {
        FlowLayout {
            filterMenu("Language", selection: filters.language.map(ModelCapabilities.languageName)) {
                Button("All languages") { filters.language = nil }
                Divider()
                ForEach(availableLanguages, id: \.self) { code in
                    Button(ModelCapabilities.languageName(code)) { filters.language = code }
                }
            }
            filterMenu("Size", selection: filters.size?.label) {
                Button("Any size") { filters.size = nil }
                Divider()
                ForEach(DiscoveryFilters.SizeBucket.allCases) { bucket in
                    Button(bucket.label) { filters.size = bucket }
                }
            }
            filterMenu("Performance", selection: filters.performance?.label) {
                Button("Any") { filters.performance = nil }
                Divider()
                ForEach(DiscoveryFilters.Performance.allCases) { p in
                    Button(p.label) { filters.performance = p }
                }
            }
            filterMenu("Format", selection: filters.format?.displayName) {
                Button("Any format") { filters.format = nil }
                Divider()
                // Only formats a shipped runtime can load are offered (§12).
                ForEach(ModelRuntimeRegistry.supportedFormats) { format in
                    Button(format.displayName) { filters.format = format }
                }
            }
            filterMenu("Runtime", selection: filters.engine?.displayName) {
                Button("Any runtime") { filters.engine = nil }
                Divider()
                ForEach(ModelRuntimeRegistry.all) { runtime in
                    Button(runtime.engine.detailName) { filters.engine = runtime.engine }
                }
            }
            filterMenu("Source", selection: filters.trust?.label) {
                Button("Any source") { filters.trust = nil }
                Divider()
                ForEach(ModelTrust.allCases) { trust in
                    Button(trust.label) { filters.trust = trust }
                }
            }
            filterMenu("Compatibility", selection: filters.compatibility?.label) {
                Button("Any") { filters.compatibility = nil }
                Divider()
                ForEach(DiscoveryFilters.CompatibilityFilter.allCases) { c in
                    Button(c.label) { filters.compatibility = c }
                }
            }
        }
    }

    @ViewBuilder
    private func filterMenu<Content: View>(_ title: String, selection: String?,
                                           @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(selection ?? title)
                    .font(Tokens.TypeScale.micro.weight(selection == nil ? .regular : .semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(selection == nil ? Tokens.Color.textSec : Tokens.Color.accent)
            .padding(.horizontal, Tokens.Space.x2)
            .padding(.vertical, 5)
            .background(Capsule().fill(selection == nil ? Tokens.Color.fillQuieter
                                       : Tokens.Color.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(title) filter, \(selection ?? "not set")")
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        if !filters.isEmpty {
            FlowLayout {
                if let language = filters.language {
                    FilterChip(text: ModelCapabilities.languageName(language)) { filters.language = nil }
                }
                if let size = filters.size { FilterChip(text: size.label) { filters.size = nil } }
                if let p = filters.performance { FilterChip(text: p.label) { filters.performance = nil } }
                if let f = filters.format { FilterChip(text: f.displayName) { filters.format = nil } }
                if let e = filters.engine { FilterChip(text: e.displayName) { filters.engine = nil } }
                if let t = filters.trust { FilterChip(text: t.label) { filters.trust = nil } }
                if let c = filters.compatibility { FilterChip(text: c.label) { filters.compatibility = nil } }
                Button("Clear all") { filters.clear() }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private var discoverEmptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text(query.isEmpty ? "Nothing matches these filters"
                 : "No models found for “\(query)”")
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.text)
            Text("Try:")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            FlowLayout {
                ForEach(["Whisper", "Qwen", "multilingual", "Arabic", "French", "fast"], id: \.self) { suggestion in
                    Button(suggestion) {
                        filters.clear()
                        query = suggestion
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.accent)
                    .padding(.horizontal, Tokens.Space.x2)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tokens.Color.accent.opacity(0.12)))
                }
            }
            HStack(spacing: Tokens.Space.x3) {
                Button("Search Hugging Face") { openHubBrowser() }
                .buttonStyle(.plain)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.accent)
                if !filters.isEmpty {
                    Button("Clear filters") { filters.clear() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.textSec)
                }
            }
        }
        .padding(Tokens.Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }

    // MARK: Storage (§23)

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            ModelSectionHeader("Storage") {
                Button("Manage storage") { route = .storage }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.accent)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                StorageBar(report: storageReport)
                VStack(spacing: 0) {
                    ForEach(storageReport.items.prefix(5)) { item in
                        HStack(spacing: Tokens.Space.x2) {
                            Text(item.name)
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textSec)
                                .lineLimit(1)
                            if item.id == registry.activeId {
                                Text("Active").font(Tokens.TypeScale.micro)
                                    .foregroundStyle(Tokens.Color.success)
                            }
                            Spacer(minLength: Tokens.Space.x3)
                            Text(ModelStorageReport.label(item.bytes))
                                .font(Tokens.TypeScale.caption)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        .padding(.vertical, 4)
                    }
                    if storageReport.incompleteBytes > 0 {
                        HStack(spacing: Tokens.Space.x2) {
                            Text("Interrupted downloads")
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.warn)
                            Spacer(minLength: Tokens.Space.x3)
                            Text(ModelStorageReport.label(storageReport.incompleteBytes))
                                .font(Tokens.TypeScale.caption)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(Tokens.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: nil, elevated: false)
        }
    }

    // MARK: First run / empty (§45, §46)

    private var firstRunView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    Text("Choose your speech model")
                        .font(Tokens.TypeScale.largeTitle)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Install an on-device model to start transcribing. Everything runs on your Mac — audio never leaves it.")
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Tokens.Space.x3) {
                    IconTile(hw.isAppleSilicon ? "memorychip.fill" : "cpu", size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("We detected")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                        Text(hw.summary)
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.text)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Tokens.Space.x4)
                .card(padding: nil, elevated: false)

                if let recommended = ModelRecommender.awards(from: ModelCatalogService.builtIn, hw: hw)
                    .first(where: { $0.award == .bestForYourMac }) {
                    VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                        ModelSectionHeader("Recommended")
                        RecommendationCard(
                            recommendation: recommended,
                            lifecycle: registry.lifecycle(of: recommended.model.id),
                            actions: actions
                        )
                        .frame(maxWidth: 420)
                    }
                }

                HStack(spacing: Tokens.Space.x3) {
                    Button("Choose another model") {
                        showAllDiscover = true
                        searchFocused = true
                    }
                    .secondaryAction()
                    Button("Import model") { importer.presentOpenPanel() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.textSec)
                    Spacer(minLength: 0)
                }

                if showAllDiscover { discoverSection }
                if !queue.activeJobs.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                        ModelSectionHeader("Installing")
                        ForEach(queue.activeJobs) { job in
                            DownloadProgressPanel(
                                job: job,
                                onPause: { queue.pause(job.id) },
                                onResume: { queue.resume(job.id) },
                                onCancel: { queue.cancel(job.id) },
                                onRetry: { queue.retry(job.id) }
                            )
                        }
                    }
                }
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    // MARK: Loading (§83)

    /// The page's real shell with placeholder rows, so nothing jumps when the
    /// first disk scan lands.
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x6) {
            header
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                ModelSectionHeader("Active model")
                ModelRowSkeleton()
                    .padding(Tokens.Space.x4)
                    .card(padding: nil, elevated: false)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                ModelSectionHeader("Installed")
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in ModelRowSkeleton() }
                }
                .card(padding: nil, elevated: false)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.x8)
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Drop target (§34)

    private var dropOverlay: some View {
        ZStack {
            Tokens.Color.bgDeep.opacity(0.7)
            VStack(spacing: Tokens.Space.x3) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Tokens.Color.accent)
                Text("Drop to import model")
                    .font(Tokens.TypeScale.title2)
                    .foregroundStyle(Tokens.Color.text)
                Text("Core ML Whisper folder or GGUF speech model")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Keyboard (§56)

    private var keyboardShortcuts: some View {
        VStack(spacing: 0) {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("") { openHubBrowser() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func moveSelection(_ direction: MoveCommandDirection, in models: [ModelDescriptor]) {
        guard !models.isEmpty else { return }
        guard direction == .up || direction == .down else { return }
        let current = selectedInstalledId.flatMap { id in models.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = direction == .down ? min(current + 1, models.count - 1) : max(current - 1, 0)
        } else {
            next = 0
        }
        selectedInstalledId = models[next].id
    }

    // MARK: Discovery data

    /// Everything discoverable: the shipped catalog plus whatever the current
    /// search turned up. The catalog is always present, so discovery keeps
    /// working with no network (§26).
    private var allDiscoverCandidates: [ModelDescriptor] {
        let installed = registry.installedIds
        let builtIn = ModelCatalogService.builtIn.filter { !installed.contains($0.id) }
        let remote = remoteResults.filter { model in
            !installed.contains(model.id) && !builtIn.contains { $0.id == model.id }
        }
        return builtIn + remote
    }

    private var discoverResults: [ModelDescriptor] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var models = allDiscoverCandidates.filter { model in
            let verdict = ModelCompatibility.verdict(for: model, hw: hw)
            guard filters.matches(model, compatibility: verdict) else { return false }
            guard !q.isEmpty else { return true }
            return matchesQuery(model, q)
        }
        models = sorted(models)
        // The default view stays curated; "Browse all" opens the full list (§10).
        if !showAllDiscover, q.isEmpty, filters.isEmpty {
            models = Array(models.prefix(6))
        }
        return models
    }

    private var hiddenDiscoverCount: Int {
        max(0, allDiscoverCandidates.count - discoverResults.count)
    }

    private var discoverCountLabel: String? {
        let total = allDiscoverCandidates.count
        guard total > 0 else { return nil }
        let shown = discoverResults.count
        return shown == total ? countLabel(total, "model") : "\(shown) of \(total)"
    }

    /// §11: name, provider, language, architecture, repository id and tags.
    private func matchesQuery(_ model: ModelDescriptor, _ q: String) -> Bool {
        if model.displayName.lowercased().contains(q) { return true }
        if model.provider.lowercased().contains(q) { return true }
        if model.repositoryId.lowercased().contains(q) { return true }
        if model.engine.displayName.lowercased().contains(q) { return true }
        if model.format.displayName.lowercased().contains(q) { return true }
        if model.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        if model.blurb.lowercased().contains(q) { return true }
        if model.capabilities.languages.contains(where: {
            $0 == q || ModelCapabilities.languageName($0).lowercased().contains(q)
        }) { return true }
        if q == "multilingual", model.capabilities.isMultilingual { return true }
        return false
    }

    private func sorted(_ models: [ModelDescriptor]) -> [ModelDescriptor] {
        switch sort {
        case .recommended:
            return models.sorted { ModelRecommender.score($0, hw: hw) > ModelRecommender.score($1, hw: hw) }
        case .quality:
            return models.sorted { ($0.accuracy.fraction ?? -1) > ($1.accuracy.fraction ?? -1) }
        case .speed:
            return models.sorted { ($0.speed.fraction ?? -1) > ($1.speed.fraction ?? -1) }
        case .size:
            return models.sorted {
                ($0.resources.diskBytes == 0 ? Int64.max : $0.resources.diskBytes)
                    < ($1.resources.diskBytes == 0 ? Int64.max : $1.resources.diskBytes)
            }
        case .popularity, .recentlyUpdated:
            // Hub-side ordering already applied to remote results; the shipped
            // catalog has no popularity signal, so it keeps its curated order.
            return models
        }
    }

    private var availableLanguages: [String] {
        ModelLanguageSets.filterLanguages(from: ModelCatalogService.builtIn + remoteResults)
    }

    // MARK: Search

    private func debounceSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            debouncedQuery = text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 { runRemoteSearch(trimmed) }
            else { remoteResults = []; searchError = nil }
        }
    }

    private func runRemoteSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard metadata.isOnline else {
            searchError = "You're offline."
            return
        }
        isSearching = true
        searchError = nil
        Task {
            defer { isSearching = false }
            do {
                var hubQuery = HFHubQuery()
                hubQuery.text = trimmed
                switch sort {
                case .recentlyUpdated: hubQuery.sort = .recentlyUpdated
                case .popularity:      hubQuery.sort = .downloads
                default:               hubQuery.sort = .trending
                }
                // The page's Discover grid stays curated: only builds a shipped
                // runtime can load. Everything else on the Hub is one click
                // away in the browser sheet, with the reason attached (§69).
                let models = try await HFHub.searchInstallable(hubQuery)
                remoteResults = models
                    .filter(\.canInstall)
                    .map(ModelCatalogService.descriptor(forHubModel:))
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    /// The Hub browser is a window, not a sheet: browsing is open-ended, and a
    /// macOS sheet can't be resized. `AppDelegate` owns the window.
    private func openHubBrowser() {
        NotificationCenter.default.post(
            name: .openHubBrowser,
            object: query.trimmingCharacters(in: .whitespaces))
    }

    private func refreshAll() {
        catalog.refreshIfNeeded(force: true)
        metadata.ensure(registry.descriptor(for: registry.activeId).repositoryId, force: true)
        if !debouncedQuery.isEmpty { runRemoteSearch(debouncedQuery) }
        Task {
            await registry.scan()
            await refreshStorage()
        }
    }

    private func prefetchActiveMetadata() {
        // One background fetch for the models the user actually has, so update
        // detection and licence data are ready without a per-render request.
        for model in registry.installedDescriptors.prefix(6) where !model.repositoryId.isEmpty {
            metadata.ensure(model.repositoryId)
        }
    }

    private func refreshStorage() async {
        storageReport = await registry.storageReport()
    }

    // MARK: Actions

    private var actions: ModelActions {
        ModelActions(
            activate: { id in
                registry.activate(id)
                LanguageProfile.shared.record(settings.language)
            },
            install: { model in installFlow(model) },
            openDetails: { model in detailModel = model },
            test: { id in route = .test(id) },
            benchmark: { id in route = .benchmark(id) },
            compare: { id in
                let others = registry.installedDescriptors.map(\.id).filter { $0 != id }
                route = .compare([id] + Array(others.prefix(1)))
            },
            requestRemove: { model in
                switch registry.canRemove(model.id) {
                case .success: removalTarget = model
                case .failure(let refusal): removalRefusal = refusal.localizedDescription
                }
            },
            repair: { model in
                Task {
                    _ = await registry.verify(model.id)
                    queue.enqueue(model, activate: model.id == registry.activeId)
                }
            },
            update: { model in
                metadata.ensure(model.repositoryId, force: true)
                detailModel = model
            },
            reveal: { model in
                let path = registry.installations[model.id]?.installedPath
                if let path, !path.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    storageLocation.revealInFinder()
                }
            },
            toggleFavorite: { id in registry.toggleFavorite(id) },
            openRepository: { model in NSWorkspace.shared.open(model.repositoryURL) },
            copyIdentifier: { model in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.repositoryId, forType: .string)
                state.showToast("Copied \(model.repositoryId)")
            },
            pause: { id in queue.pause(id) },
            resume: { id in queue.resume(id) },
            cancel: { id in queue.cancel(id) },
            retry: { id in queue.retry(id) }
        )
    }

    /// Install, with the pre-download checks the user needs to see first (§9, §87).
    private func installFlow(_ model: ModelDescriptor) {
        let compat = ModelCompatibility.evaluate(model, hw: hw)
        // A genuine runtime incompatibility, or not enough disk to finish, are
        // the only cases that stop the download — memory pressure is a warning
        // shown on the detail page, never a block.
        if compat.verdict.isBlocking || compat.diskIsCritical {
            detailModel = model
            return
        }
        queue.enqueue(model)
    }

    private func performRemove(_ model: ModelDescriptor) {
        removalTarget = nil
        Task {
            let freed = await registry.remove(model.id)
            await refreshStorage()
            if freed > 0 {
                state.showToast("Removed \(model.displayName) — \(ModelStorageReport.label(freed)) freed.")
            }
        }
    }

    private func removalMessage(_ model: ModelDescriptor) -> String {
        let bytes = registry.removableBytes(model.id)
        var text = bytes > 0
            ? "This will free \(ModelStorageReport.label(bytes)) of disk space."
            : "The model's files will be deleted."
        if benchmarks.result(for: model.id) != nil {
            text += " Your benchmark history will be kept."
        }
        return text
    }

    private func openCompare() {
        let ids = registry.installedDescriptors.map(\.id)
        guard ids.count >= 2 else { return }
        route = .compare(Array(ids.prefix(2)))
    }

    // MARK: Sheets

    @ViewBuilder
    private func routeSheet(_ route: ModelsRoute) -> some View {
        switch route {
        case .test(let id):
            ModelTestSheet(modelId: id) { self.route = nil }
        case .benchmark(let id):
            ModelBenchmarkSheet(modelId: id) { self.route = nil }
        case .compare(let ids):
            ModelCompareSheet(initialIds: ids) { self.route = nil }
        case .importModel:
            ModelImportSheet { self.route = nil }
        case .storage:
            ModelStorageSheet(report: storageReport,
                              onRefresh: { Task { await refreshStorage() } }) { self.route = nil }
        case .downloads:
            DownloadCenterSheet { self.route = nil }
        case .pasteURL:
            PasteRepositorySheet(onInstall: { model in
                self.route = nil
                detailModel = model
            }, onClose: { self.route = nil })
        }
    }

    // MARK: Formatting

    private func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func relative(_ date: Date) -> String {
        // RelativeDateTimeFormatter renders a just-happened event as "in 0s",
        // which reads as a future time. Anything inside a minute is "just now".
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Model load bar

/// Stepped progress for a model LOAD (distinct from a download). WhisperKit
/// reports only coarse state transitions, so this shows the phase plus a bar
/// that always advances.
struct ModelLoadBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack(spacing: Tokens.Space.x2) {
                ProgressView().controlSize(.small)
                Text(state.modelLoadPhase.isEmpty ? "Loading model…" : state.modelLoadPhase)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                Text("\(Int((state.modelLoadProgress * 100).rounded()))%")
                    .font(Tokens.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            ProgressView(value: min(max(state.modelLoadProgress, 0.02), 1))
                .progressViewStyle(.linear)
                .tint(Tokens.Color.accent)
                .animation(Tokens.Motion.ease, value: state.modelLoadProgress)
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.fillQuieter,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading model, \(Int(state.modelLoadProgress * 100)) percent")
    }
}
