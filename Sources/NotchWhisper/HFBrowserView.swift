import SwiftUI
import AppKit

// MARK: - Hugging Face browser
//
// The Hub, searchable from inside the app. This is a window rather than a
// sheet: browsing is an open-ended task, and a macOS SwiftUI sheet cannot be
// resized by the user no matter what frame its content declares — it also
// adopts the content's *minimum* width, so a sheet here was both small and
// stuck. `AppDelegate.showHubBrowser` hosts this view in a normal resizable
// window instead.
//
// Three things make it more than a list of names:
//
//   · Every field the API returns is shown somewhere. Popularity, lineage,
//     licence, published WER, precision breakdown, inference providers — the
//     row carries the summary, the expanded panel carries the rest.
//   · Models this app can't run are shown, not hidden, with the reason (§69).
//     Hiding them is what made search feel broken.
//   · Installing happens here. Expanding a row fetches the file list and lists
//     the real installable builds with exact sizes, so nothing is downloaded
//     on a guess.

struct HFBrowserView: View {
    let actions: ModelActions
    /// Opens the app's own detail page for a build.
    let onOpenDetails: (ModelDescriptor) -> Void

    @ObservedObject private var opener = HubBrowserOpener.shared
    @StateObject private var search = HFHubSearchModel()
    @FocusState private var searchFocused: Bool
    @State private var expanded: String?

    private var visible: [HFHubModel] { search.visible }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Tokens.Color.hairline)
            controls
            Divider().overlay(Tokens.Color.hairline)
            resultsArea
        }
        // A finite *ideal* is what sizes the window: `NSHostingView` hands the
        // window its fitting size, and a results list with no ideal height
        // reports thousands of points, so the window opened screen-tall. The
        // min/max keep it freely resizable around that.
        // 600 is just above the measured floor for the header + search +
        // facets block (592pt); below that the window would clip its own
        // controls rather than scroll them.
        .frame(minWidth: 780, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 600, idealHeight: 820, maxHeight: .infinity,
               alignment: .top)
        .background(Tokens.Color.bg)
        .environment(\.colorScheme, .dark)
        .task {
            searchFocused = true
            await search.seed(opener.seed)
        }
        // Reopening the window from the Models page re-seeds the field rather
        // than leaving the last search sitting there.
        .onChange(of: opener.openRequests) { _, _ in
            searchFocused = true
            Task { await search.seed(opener.seed) }
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("🤗").font(.system(size: 16))
                    Text("Hugging Face")
                        .font(Tokens.TypeScale.title1)
                        .foregroundStyle(Tokens.Color.text)
                }
                Text("Search every speech model on the Hub and install the ones this Mac can run.")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Link(destination: URL(string: "https://huggingface.co/models?pipeline_tag=automatic-speech-recognition")!) {
                HStack(spacing: 3) {
                    Text("Open the Hub")
                    Image(systemName: "arrow.up.right")
                }
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Tokens.Space.x5)
        // The window draws its content under a transparent titlebar, so the
        // first row has to start below the traffic lights.
        .padding(.top, 34)
        .padding(.bottom, Tokens.Space.x4)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            searchField
            HStack(spacing: Tokens.Space.x2) {
                scopePicker
                Spacer(minLength: Tokens.Space.x2)
                sortMenu
            }
            facetBar
            if !search.query.text.isEmpty || search.query.hasFacets { activeFacetChips }
            summaryLine
            if let repoId = search.pastedRepoId, !search.results.contains(where: { $0.repoId == repoId }) {
                pastedRepoBanner(repoId)
            }
        }
        .padding(.horizontal, Tokens.Space.x5)
        .padding(.vertical, Tokens.Space.x4)
    }

    private var searchField: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.textTert)
            TextField("Search Hugging Face — model, org, language, or paste a repository URL",
                      text: $search.query.text)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
                .focused($searchFocused)
                .onSubmit { search.reloadNow() }
                .onChange(of: search.query.text) { _, _ in search.queryChanged() }
                .accessibilityLabel("Search Hugging Face")
            if search.isLoading {
                ProgressView().controlSize(.small)
            } else if !search.query.text.isEmpty {
                Button {
                    search.query.text = ""
                    search.reloadNow()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Color.textTert)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, 10)
        .background(Tokens.Color.fillQuiet, in: Capsule())
        .overlay(Capsule().strokeBorder(
            searchFocused ? Tokens.Color.accent.opacity(0.55) : Tokens.Color.hairline, lineWidth: 1))
    }

    /// Installable-first is the honest default. "Runs here" asks the Hub for
    /// the formats this app can load; "Everything" drops that and labels each
    /// result with the reason it can't run (§69).
    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(HFHubSearchModel.Scope.allCases) { scope in
                scopeButton(scope)
            }
        }
        .padding(2)
        .background(Capsule().fill(Tokens.Color.fillQuieter))
        .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result scope")
    }

    private func scopeButton(_ scope: HFHubSearchModel.Scope) -> some View {
        let selected = search.scope == scope
        return Button { search.setScope(scope) } label: {
            Text(scope.label)
                .font(Tokens.TypeScale.micro.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Tokens.Color.onAccent : Tokens.Color.textSec)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Tokens.Color.accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $search.query.sort) {
                ForEach(HFHub.Sort.allCases) { order in
                    Label(order.label, systemImage: order.symbol).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: search.query.sort.symbol).font(.system(size: 9, weight: .semibold))
                Text(search.query.sort.label).font(Tokens.TypeScale.micro)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Tokens.Color.textSec)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onChange(of: search.query.sort) { _, _ in search.reloadNow() }
        .accessibilityLabel("Sort by \(search.query.sort.label)")
    }

    private var facetBar: some View {
        FlowLayout {
            facetMenu("Task", selection: search.query.task == nil
                      ? "Any task"
                      : HFHub.tasks.first { $0.id == search.query.task }?.label) {
                ForEach(HFHub.tasks, id: \.id) { task in
                    Button(task.label) { setFacet { $0.task = task.id } }
                }
                Divider()
                // Without a task the Hub returns its whole Core ML / GGUF
                // population, so these results are screened for speech.
                Button("Any task (speech only)") { setFacet { $0.task = nil } }
            }
            facetMenu("Format", selection: HFHub.formatTags.first { $0.tag == search.query.formatTag }?.label) {
                Button("Any format") { setFacet { $0.formatTag = nil } }
                Divider()
                ForEach(HFHub.formatTags, id: \.tag) { entry in
                    Button(entry.label) { setFacet { $0.formatTag = entry.tag } }
                }
            }
            facetMenu("Library", selection: HFHub.libraries.first { $0.id == search.query.library }?.label
                      ?? search.query.library) {
                Button("Any library") { setFacet { $0.library = nil } }
                Divider()
                ForEach(HFHub.libraries, id: \.id) { entry in
                    Button(entry.label) { setFacet { $0.library = entry.id } }
                }
            }
            facetMenu("Language",
                      selection: search.query.language.map(ModelCapabilities.languageName)) {
                Button("Any language") { setFacet { $0.language = nil } }
                if !languagesInResults.isEmpty {
                    Section("In these results") {
                        ForEach(languagesInResults, id: \.self) { code in
                            Button(ModelCapabilities.languageName(code)) { setFacet { $0.language = code } }
                        }
                    }
                }
                Section("All languages") {
                    ForEach(allLanguages, id: \.self) { code in
                        Button(ModelCapabilities.languageName(code)) { setFacet { $0.language = code } }
                    }
                }
            }
            facetMenu("Licence", selection: HFHub.licenses.first { $0.id == search.query.license }?.label) {
                Button("Any licence") { setFacet { $0.license = nil } }
                Divider()
                ForEach(HFHub.licenses, id: \.id) { entry in
                    Button(entry.label) { setFacet { $0.license = entry.id } }
                }
            }
        }
    }

    /// Every language the facet can filter by.
    ///
    /// This is a server-side `filter=<code>` query, so the menu must offer the
    /// full set — its whole purpose is finding models that are *not* in the
    /// current results. An earlier version listed only codes the loaded page
    /// happened to declare, which silently hid most of the world's languages
    /// as soon as a few results carried six between them.
    ///
    /// The list is therefore every ISO-639-1 language, not a curated subset:
    /// the Hub indexes languages as plain tags and has models for far more of
    /// them than the shipped runtimes were trained on, and it isn't this menu's
    /// place to decide which languages are worth looking for. Whisper's
    /// three-letter codes (`haw`, `yue`, `jw`) and anything the current results
    /// declare are unioned in on top.
    private static let isoLanguages: [String] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 && Locale.current.localizedString(forLanguageCode: $0) != nil }

    private var allLanguages: [String] {
        let codes = Set(Self.isoLanguages)
            .union(ModelLanguageSets.whisperMultilingualV3)
            .union(search.results.flatMap(\.languages))
        return codes.sorted {
            ModelCapabilities.languageName($0) < ModelCapabilities.languageName($1)
        }
    }

    /// A shortcut group: the languages the loaded results actually declare,
    /// most common first. Never the only thing on offer.
    private var languagesInResults: [String] { search.languagesInResults }

    @ViewBuilder
    private func facetMenu<Content: View>(_ title: String, selection: String?,
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
    private var activeFacetChips: some View {
        if search.query.hasFacets {
            FlowLayout {
                if search.query.task != HFHubQuery.defaultTask {
                    let label = search.query.task
                        .flatMap { id in HFHub.tasks.first { $0.id == id }?.label } ?? "Any task"
                    FilterChip(text: label) { setFacet { $0.task = HFHubQuery.defaultTask } }
                }
                if let tag = search.query.formatTag {
                    FilterChip(text: HFHub.formatTags.first { $0.tag == tag }?.label ?? tag) {
                        setFacet { $0.formatTag = nil }
                    }
                }
                if let lib = search.query.library {
                    FilterChip(text: HFHub.libraries.first { $0.id == lib }?.label ?? lib) {
                        setFacet { $0.library = nil }
                    }
                }
                if let lang = search.query.language {
                    FilterChip(text: ModelCapabilities.languageName(lang)) { setFacet { $0.language = nil } }
                }
                if let lic = search.query.license {
                    FilterChip(text: HFHub.licenses.first { $0.id == lic }?.label ?? lic) {
                        setFacet { $0.license = nil }
                    }
                }
                if let author = search.query.author {
                    FilterChip(text: "@\(author)") { setFacet { $0.author = nil } }
                }
                Button("Clear filters") { setFacet { $0.clearFacets() } }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private func setFacet(_ mutate: (inout HFHubQuery) -> Void) {
        mutate(&search.query)
        search.reloadNow()
    }

    @ViewBuilder
    private var summaryLine: some View {
        HStack(spacing: Tokens.Space.x2) {
            if search.isLoading && search.results.isEmpty {
                Text("Searching the Hub…")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
            } else if !search.results.isEmpty {
                Text(countSummary)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                if search.scope == .installable {
                    Button("Search the whole Hub") { search.setScope(.everything) }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Three different empty states, because "no results" and "results that
    /// can't be installed" are different problems with different next steps.
    private var emptyTitle: String {
        if search.scope == .installable, !search.results.isEmpty {
            return search.results.count == 1
                ? "The one match doesn't ship a build this Mac can run"
                : "None of the \(search.results.count) matches ship a build this Mac can run"
        }
        return search.query.text.isEmpty
            ? "Nothing matches these filters"
            : "No models match “\(search.query.text)”"
    }

    private var emptyMessage: String {
        if search.scope == .installable, !search.results.isEmpty {
            return "They're Core ML or GGUF repositories, but none has the compiled weights or the mmproj audio projector a shipped runtime needs."
        }
        return search.scope == .installable
            ? "Nothing in a Core ML or GGUF build matched. Everything searches the rest of the Hub and says why each result can't run."
            : "Try a broader term, or clear a filter."
    }

    private var countSummary: String {
        let shown = visible.count
        let noun = shown == 1 ? "model" : "models"
        let more = search.hasMore ? "+" : ""
        switch search.scope {
        case .installable:
            return "\(shown)\(more) \(noun) NotchWhisper can run"
        case .everything:
            return "\(shown)\(more) \(noun) on the Hub · \(search.installable.count) can run here"
        }
    }

    private func pastedRepoBanner(_ repoId: String) -> some View {
        InlineBanner(
            kind: .info,
            title: "Open \(repoId) directly",
            message: "That looks like a repository reference. Fetch it by id instead of searching for it.",
            actionTitle: "Fetch repository",
            action: {
                setFacet {
                    $0.text = repoId.split(separator: "/").last.map(String.init) ?? repoId
                    $0.author = repoId.split(separator: "/").first.map(String.init)
                }
                expanded = repoId
            }
        )
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        ScrollView {
            LazyVStack(spacing: Tokens.Space.x2) {
                if let error = search.error {
                    InlineBanner(kind: .error, title: "Couldn't reach Hugging Face",
                                 message: error, actionTitle: "Retry",
                                 action: { search.reloadNow() })
                        .padding(.bottom, Tokens.Space.x2)
                }

                ForEach(visible) { model in
                    HFResultRow(
                        model: model,
                        isExpanded: expanded == model.repoId,
                        actions: actions,
                        onToggle: {
                            withAnimation(Tokens.Motion.ease(reduceMotion: Tokens.A11y.reduceMotion)) {
                                expanded = expanded == model.repoId ? nil : model.repoId
                            }
                        },
                        onOpenDetails: onOpenDetails,
                        onSearchAuthor: { author in
                            setFacet { $0.author = author; $0.text = "" }
                        }
                    )
                }

                if visible.isEmpty, !search.isLoading, search.error == nil {
                    emptyState
                }

                if search.hasMore, !visible.isEmpty {
                    loadMoreRow
                }
            }
            .padding(Tokens.Space.x5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var loadMoreRow: some View {
        Group {
            if search.isLoadingMore {
                HStack(spacing: Tokens.Space.x2) {
                    ProgressView().controlSize(.small)
                    Text("Loading more…")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            } else {
                Button("Load more results") { search.loadMore() }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.x4)
        .onAppear { search.loadMore() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text(emptyTitle)
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.text)
            Text(emptyMessage)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout {
                ForEach(["whisper", "coreml", "qwen", "parakeet", "distil", "turbo"], id: \.self) { term in
                    Button(term) {
                        setFacet { $0.clearFacets(); $0.text = term }
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.accent)
                    .padding(.horizontal, Tokens.Space.x2)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tokens.Color.accent.opacity(0.12)))
                }
            }
            if search.scope == .installable {
                Button("Search the whole Hub") { search.setScope(.everything) }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
            }
        }
        .padding(Tokens.Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil, elevated: false)
    }
}

// MARK: - Window plumbing

/// Carries the seed query from whatever opened the browser into the window's
/// view, and lets a reopen re-seed a window that is already on screen.
@MainActor
final class HubBrowserOpener: ObservableObject {
    static let shared = HubBrowserOpener()
    @Published private(set) var seed = ""
    /// Bumped on every open request, including ones that only refocus an
    /// existing window — the view watches this rather than `seed`, so opening
    /// twice with the same text still re-runs the search.
    @Published private(set) var openRequests = 0

    private init() {}

    func request(seed: String) {
        self.seed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        openRequests += 1
    }
}

/// The browser window's root: the Hub view plus the app's own model detail
/// sheet, so opening a build's details never has to reach into another window.
struct HubBrowserWindow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var queue = ModelDownloadQueue.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @State private var detailModel: ModelDescriptor?
    @State private var removalRefusal: String?

    var body: some View {
        let _ = theme.theme
        HFBrowserView(actions: actions, onOpenDetails: { detailModel = $0 })
            .sheet(item: $detailModel) { model in
                ModelDetailSheet(model: model, actions: actions) { detailModel = nil }
                    .environmentObject(state)
                    .environmentObject(settings)
            }
            .alert("Can't remove this model", isPresented: Binding(
                get: { removalRefusal != nil }, set: { if !$0 { removalRefusal = nil } }
            )) {
                Button("OK", role: .cancel) { removalRefusal = nil }
            } message: {
                Text(removalRefusal ?? "")
            }
    }

    /// The subset of model actions that makes sense away from the Models page.
    /// Test, benchmark and compare live on that page's own sheets, so they open
    /// the details view here instead of a dead end.
    private var actions: ModelActions {
        ModelActions(
            activate: { id in
                registry.activate(id)
                LanguageProfile.shared.record(settings.language)
            },
            install: { model in
                let compat = ModelCompatibility.evaluate(model)
                // A real runtime incompatibility, or not enough disk to finish,
                // sends the user to the details view rather than starting a
                // download that cannot succeed (§9, §87).
                if compat.verdict.isBlocking || compat.diskIsCritical {
                    detailModel = model
                } else {
                    queue.enqueue(model)
                }
            },
            openDetails: { detailModel = $0 },
            test: { id in detailModel = registry.descriptor(for: id) },
            benchmark: { id in detailModel = registry.descriptor(for: id) },
            compare: { id in detailModel = registry.descriptor(for: id) },
            requestRemove: { model in
                switch registry.canRemove(model.id) {
                case .success:
                    Task { _ = await registry.remove(model.id) }
                case .failure(let refusal):
                    removalRefusal = refusal.localizedDescription
                }
            },
            repair: { model in
                Task {
                    _ = await registry.verify(model.id)
                    queue.enqueue(model, activate: model.id == registry.activeId)
                }
            },
            update: { model in
                HFMetadataCache.shared.ensure(model.repositoryId, force: true)
                detailModel = model
            },
            reveal: { model in
                let path = registry.installations[model.id]?.installedPath
                if let path, !path.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    ModelStorageLocation.shared.revealInFinder()
                }
            },
            toggleFavorite: { registry.toggleFavorite($0) },
            openRepository: { NSWorkspace.shared.open($0.repositoryURL) },
            copyIdentifier: { model in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.repositoryId, forType: .string)
                state.showToast("Copied \(model.repositoryId)")
            },
            pause: { queue.pause($0) },
            resume: { queue.resume($0) },
            cancel: { queue.cancel($0) },
            retry: { queue.retry($0) }
        )
    }
}
