import SwiftUI
import AVFoundation

/// The main window shell — a translucent, vibrant sidebar (the desktop glows
/// through it, as in Finder and Music) beside a lit graphite content pane.
/// Nav is grouped the way the product is used: capture, the library you
/// build, and the things you tune.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var inputs = AudioInputManager.shared

    @ViewState private var nav: Nav = .home
    @ViewState private var aiTab: AITab = .connections
    @Namespace private var pill

    enum Nav: String, CaseIterable, Identifiable {
        case home, upload, meetings, transcripts, dictionary, models, apps, ai
        var id: String { rawValue }
        var label: String {
            switch self {
            case .home: return "Home"
            case .upload: return "Files"
            case .meetings: return "Meetings"
            case .transcripts: return "Transcripts"
            case .dictionary: return "Dictionary"
            case .models: return "Models"
            case .apps: return "Apps"
            case .ai: return "AI"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house"
            case .upload: return "doc.text"
            case .meetings: return "person.2.wave.2"
            case .transcripts: return "text.quote"
            case .dictionary: return "character.book.closed"
            case .models: return "cpu"
            case .apps: return "square.grid.2x2"
            case .ai: return "sparkles"
            }
        }
    }

    /// The sidebar's sections, in order. `nil` title = no header.
    private let sections: [(title: String?, items: [Nav])] = [
        (nil, [.home]),
        ("Transcribe", [.upload, .meetings]),
        ("Library", [.transcripts, .dictionary]),
        ("Customize", [.models, .apps, .ai]),
    ]

    var body: some View {
        let _ = theme.theme
        HStack(spacing: 0) {
            sidebar
            Hairline(vertical: true).ignoresSafeArea()
            detail
        }
        // The window draws under a transparent titlebar. Owning the top inset
        // (sidebar clears the traffic lights, pages keep their own margin)
        // keeps the layout identical at every titlebar height.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: Tokens.Layout.minWinW, maxWidth: Tokens.Layout.maxWinW,
               minHeight: Tokens.Layout.minWinH, maxHeight: Tokens.Layout.maxWinH)
        .tint(Tokens.Color.accent)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .openAIPage)) { note in
            if let raw = note.object as? String, let requested = AITab(rawValue: raw) {
                aiTab = requested
            }
            go(.ai)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAppsPage)) { _ in
            go(.apps)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainPage)) { note in
            if let raw = note.object as? String, let page = Nav(rawValue: raw) { go(page) }
        }
    }

    private func go(_ page: Nav) {
        withAnimation(Tokens.Motion.select(reduceMotion: Tokens.A11y.reduceMotion)) { nav = page }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sections.indices, id: \.self) { i in
                    let section = sections[i]
                    if let title = section.title {
                        Text(title)
                            .font(Tokens.TypeScale.eyebrow)
                            .foregroundStyle(Tokens.Color.textTert)
                            .padding(.leading, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 5)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.items) { item in
                        SidebarRow(item: item, selected: nav == item, namespace: pill) { go(item) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, Tokens.Layout.titlebarInset)

            Spacer(minLength: Tokens.Space.x4)

            statusPanel
                .padding(.horizontal, 10)

            Hairline()
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x2)

            SidebarActionRow(icon: "gearshape", title: "Settings", shortcut: "⌘,") {
                AppDelegate.shared?.showSettings()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Tokens.Space.x3)
        }
        .frame(width: Tokens.Layout.sidebarW)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    /// Health at a glance: the engine's state always, and a line for anything
    /// that would stop a dictation — only when something is actually wrong.
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { go(.models) } label: {
                HStack(spacing: Tokens.Space.x2 + 2) {
                    StatusDot(color: engineColor, size: 7, pulsing: engineBusy)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(engineTitle)
                            .font(Tokens.TypeScale.callout.weight(.medium))
                            .foregroundStyle(Tokens.Color.text)
                            .lineLimit(1)
                        Text(ModelRegistry.shared.descriptor(for: settings.modelId).displayName)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .help("Open Models")

            if !micHealth.ok {
                issueRow(icon: "mic.slash", text: micHealth.label) {
                    AppDelegate.shared?.openSettings(.microphone)
                }
            }
            if !AutoTyper.isTrusted {
                issueRow(icon: "hand.raised", text: "Accessibility is off") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func issueRow(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.x2 + 2) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Color.warn)
                    .frame(width: 18)
                Text(text)
                    .font(Tokens.TypeScale.caption.weight(.medium))
                    .foregroundStyle(Tokens.Color.textSec)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Tokens.Color.textQuat)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
    }

    private var engineBusy: Bool { state.isDownloading || state.isLoadingModel }
    private var engineColor: SwiftUI.Color {
        switch state.modelStatus {
        case .ready: return Tokens.Color.success
        case .error: return Tokens.Color.danger
        default: return Tokens.Color.warn
        }
    }
    private var engineTitle: String {
        if state.isDownloading { return "Downloading \(Int((state.displayProgress * 100).rounded()))%" }
        if state.isLoadingModel { return "Loading model…" }
        switch state.modelStatus {
        case .ready: return "Ready"
        case .error: return "Model error"
        case .loading, .downloading: return "Preparing model…"
        case .unknown: return settings.modelPreload.preloadsAtLaunch ? "Starting up…" : "Loads on first use"
        }
    }

    /// Permission first, then whether any microphone can hear right now —
    /// named, so a closed lid or an unplugged mic shows up before dictating.
    private var micHealth: (ok: Bool, label: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return (false, "Microphone blocked") }
        guard let device = inputs.resolution(for: settings).device else {
            return (false, inputs.lidClosed ? "Lid closed · no mic" : "No microphone")
        }
        return (true, device.name)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch nav {
            case .home:        HomeView(nav: $nav)
            case .upload:      FileTranscribeView()
            case .meetings:    MeetingsView()
            case .transcripts: TranscriptsView()
            case .dictionary:  DictView()
            case .models:      ModelsView()
            case .apps:        AppsView()
            case .ai:          AIView(tab: $aiTab)
            }
        }
        .environmentObject(state)
        .environmentObject(settings)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuroraBackground())
    }
}

// MARK: - Sidebar pieces

/// One navigation row: outline glyph + label; the selection is a neutral lit
/// plate that glides between rows, with the glyph taking the accent.
private struct SidebarRow: View {
    let item: MainView.Nav
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.x2 + 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 13.5, weight: .regular))
                    .symbolVariant(selected ? .fill : .none)
                    .foregroundStyle(selected ? Tokens.Color.accent : Tokens.Color.textSec)
                    .frame(width: 18)
                Text(item.label)
                    .font(Tokens.TypeScale.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.Color.text : Tokens.Color.text.opacity(0.86))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Color.selectionFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [Tokens.Color.edgeLight, .clear],
                                                             startPoint: .top, endPoint: .bottom),
                                              lineWidth: 0.5)
                        )
                        .matchedGeometryEffect(id: "navpill", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Color.hoverFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .focusEffectDisabled()
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's footer action (Settings): same metrics as a nav row.
private struct SidebarActionRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.x2 + 2) {
                Image(systemName: icon)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.Color.textSec)
                    .frame(width: 18)
                Text(title)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text.opacity(0.86))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
    }
}

/// Hover wash + press dim for sidebar buttons that aren't nav rows.
private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }
    private struct SidebarButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @ViewState private var hovering = false
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(hovering ? Tokens.Color.hoverFill : .clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var hotkeys = HotkeyBindingStore.shared
    @ObservedObject private var modes = CustomModeStore.shared
    @Binding var nav: MainView.Nav

    @ViewState private var copiedID: UUID?

    var body: some View {
        let _ = theme.theme
        PageScroll {
            SectionHeader("Speak, and it types.", eyebrow: greeting)

            heroCard

            if state.isDownloading || state.isLoadingModel { modelProgressCard }

            statsLedger

            recentSection
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Working late"
        }
    }

    // MARK: Hero

    /// The instrument: what state the engine is in, how to start, the live
    /// signal, and the setup it will use — one object, one primary action.
    private var heroCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Tokens.Space.x6) {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    HStack(spacing: Tokens.Space.x2) {
                        StatusDot(color: dotColor, size: 8,
                                  pulsing: state.mode == .recording || state.mode == .dictating)
                        Text(statusText)
                            .font(Tokens.TypeScale.title1)
                            .foregroundStyle(Tokens.Color.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    ShortcutHint(primary: hotkeys.primary)
                }
                Spacer(minLength: Tokens.Space.x4)
                RecordButton(action: toggleRecord)
            }
            .padding(.horizontal, Tokens.Space.x6)
            .padding(.top, Tokens.Space.x6)
            .padding(.bottom, Tokens.Space.x5)

            LevelsMeter(height: 64)
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x5)

            Hairline()

            HStack(spacing: Tokens.Space.x5) {
                spec(icon: "cpu", ModelRegistry.shared.descriptor(for: settings.modelId).displayName)
                spec(icon: settings.liveDictation ? "dot.radiowaves.left.and.right" : "hand.point.up.left",
                     settings.liveDictation ? "Live dictation" : "Hold to talk")
                if settings.llmEnabled {
                    spec(icon: modes.symbol(for: settings.processingMode),
                         modes.label(for: settings.processingMode))
                }
                Spacer(minLength: Tokens.Space.x2)
                Button("Change…") { AppDelegate.shared?.openSettings(.general) }
                    .quietAction()
            }
            .padding(.horizontal, Tokens.Space.x6)
            .padding(.vertical, Tokens.Space.x3)
        }
        .card(radius: Tokens.Radius.xl, padding: nil)
        .animation(Tokens.Motion.ease(reduceMotion: Tokens.A11y.reduceMotion), value: state.mode)
    }

    private func spec(icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.Color.textTert)
            Text(text)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textSec)
                .lineLimit(1)
        }
    }

    private var dotColor: SwiftUI.Color {
        switch state.mode {
        case .idle:
            switch state.modelStatus {
            case .ready: return Tokens.Color.success
            case .error: return Tokens.Color.danger
            default: return Tokens.Color.warn
            }
        case .recording, .dictating: return Tokens.Color.record
        case .transcribing, .improving: return Tokens.Color.warn
        case .done: return Tokens.Color.success
        case .error: return Tokens.Color.danger
        }
    }
    private var statusText: String {
        switch state.mode {
        case .idle:
            switch state.modelStatus {
            case .ready: return "Ready when you are"
            case .loading, .downloading: return "Getting the model ready…"
            case .error(let e): return "Model error: \(e)"
            case .unknown:
                return settings.modelPreload.preloadsAtLaunch ? "Starting up…" : "Ready — the model loads when you start"
            }
        case .recording: return "Listening…"
        case .dictating: return "Dictating…"
        case .transcribing: return "Transcribing…"
        case .improving: return state.statusMessage.isEmpty ? "Improving…" : state.statusMessage
        case .done: return "Done — text inserted"
        case .error: return state.statusMessage.isEmpty ? "Something went wrong" : state.statusMessage
        }
    }

    private var modelProgressCard: some View {
        let progress = state.isDownloading ? state.displayProgress : state.modelLoadProgress
        return VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                ProgressView().controlSize(.small)
                Text(state.isDownloading
                     ? (state.downloadLabel.isEmpty ? "Downloading model…" : state.downloadLabel)
                     : (state.modelLoadPhase.isEmpty ? "Loading model…" : state.modelLoadPhase))
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(Tokens.TypeScale.body).monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            ProgressView(value: max(progress, 0.02))
                .tint(Tokens.Color.accent)
            if state.isDownloading, !state.downloadDetailText.isEmpty {
                Text(state.downloadDetailText)
                    .font(Tokens.TypeScale.caption).monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
        .card(radius: Tokens.Radius.lg, padding: Tokens.Space.x4, elevated: false)
    }

    // MARK: Stats

    /// Four figures on one ledger — read left to right like a spec sheet.
    private var statsLedger: some View {
        let s = computeStats()
        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            GroupLabel("Your activity")
            HStack(spacing: 0) {
                StatCell(value: s.words, label: "Words dictated")
                Hairline(vertical: true).padding(.vertical, Tokens.Space.x4)
                StatCell(value: "\(s.total)", label: "Transcripts")
                Hairline(vertical: true).padding(.vertical, Tokens.Space.x4)
                StatCell(value: "\(s.week)", label: "This week")
                Hairline(vertical: true).padding(.vertical, Tokens.Space.x4)
                StatCell(value: "\(s.corrections)", label: "Dictionary fixes")
            }
            .card(radius: Tokens.Radius.lg, padding: nil, elevated: false)
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            GroupLabel("Recent") {
                if !history.records.isEmpty {
                    Button("See all") { nav = .transcripts }
                        .quietAction()
                }
            }
            if history.records.isEmpty {
                EmptyStateView(
                    icon: "waveform",
                    title: "No transcripts yet",
                    message: hotkeys.hint(long: false)
                )
                .frame(height: 240)
                .card(padding: nil, elevated: false)
            } else {
                GroupedList(Array(history.records.prefix(5))) { rec in
                    TranscriptRow(rec: rec, copied: copiedID == rec.id, copyAction: { copy(rec) })
                } menu: { rec in
                    Button("Copy") { copy(rec) }
                    Button("Copy raw") { copyRaw(rec) }
                    Divider()
                    Button("Delete", role: .destructive) { history.delete(rec) }
                }
            }
        }
    }

    private func computeStats() -> (total: Int, week: Int, words: String, corrections: Int) {
        let recs = history.records
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? startOfToday
        let week = recs.filter { $0.createdAt >= startOfWeek }.count
        let wordCount = recs.reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace }).count }
        let corrections = recs.reduce(0) { $0 + $1.corrections.count }
        return (recs.count, week, wordCount.formatted(), corrections)
    }

    private func toggleRecord() { NotificationCenter.default.post(name: .toggleRecord, object: nil) }
    private func copy(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.finalText, forType: .string)
        copiedID = rec.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == rec.id { copiedID = nil } }
    }
    private func copyRaw(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.rawText, forType: .string)
    }
}

/// How to start, with the key drawn as a key: "Hold [Right ⌥] and speak."
struct ShortcutHint: View {
    let primary: HotkeyBinding?

    var body: some View {
        HStack(spacing: 6) {
            if let primary {
                switch primary.effectiveActivation {
                case .holdToTalk:
                    words("Hold")
                    KeyCap(text: primary.display)
                    words("and speak. Release to type.")
                case .toggleLive:
                    words("Press")
                    KeyCap(text: primary.display)
                    words("to dictate live. Press again to stop.")
                case .editSelection:
                    words("Select text, hold")
                    KeyCap(text: primary.display)
                    words("and say the change.")
                }
            } else {
                words("No shortcut yet — use the button, or add one in Settings.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(Tokens.TypeScale.body)
            .foregroundStyle(Tokens.Color.textSec)
            .lineLimit(1)
    }
}

/// One figure on the activity ledger.
struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Tokens.TypeScale.stat)
                .foregroundStyle(Tokens.Color.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Space.x5)
        .padding(.vertical, Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A grouped list: rows on one raised surface, separated by inset hairlines,
/// each with its own hover wash. Selection (a click) and the context menu are
/// attached to the whole padded row, so every highlighted point responds.
/// Lazy, so long histories stay cheap.
struct GroupedList<Item: Identifiable, Row: View, MenuItems: View>: View {
    let items: [Item]
    var onSelect: ((Item) -> Void)?
    let row: (Item) -> Row
    let menu: ((Item) -> MenuItems)?

    init(_ items: [Item], onSelect: ((Item) -> Void)? = nil,
         @ViewBuilder row: @escaping (Item) -> Row,
         @ViewBuilder menu: @escaping (Item) -> MenuItems) {
        self.items = items
        self.onSelect = onSelect
        self.row = row
        self.menu = menu
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                rowView(item)
                if index < items.count - 1 {
                    Hairline().padding(.leading, Tokens.Space.x4)
                }
            }
        }
        .card(radius: Tokens.Radius.lg, padding: nil, elevated: false)
    }

    @ViewBuilder
    private func rowView(_ item: Item) -> some View {
        let base = HoverRow { row(item) }
            .modifier(RowSelection(action: onSelect.map { select in { select(item) } }))
        if let menu {
            base.contextMenu { menu(item) }
        } else {
            base
        }
    }
}

extension GroupedList where MenuItems == EmptyView {
    init(_ items: [Item], onSelect: ((Item) -> Void)? = nil,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.onSelect = onSelect
        self.row = row
        self.menu = nil
    }
}

/// A click on the row, only when the list has something to do with it — a
/// no-op tap gesture would still swallow text selection in the row.
private struct RowSelection: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// Row padding + a hover wash, for rows inside a `GroupedList`. The hit area
/// is the whole padded row.
private struct HoverRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewState private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
            .background(hovering ? Tokens.Color.hoverFill.opacity(0.7) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Transcripts

struct TranscriptsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @ViewState private var copiedID: UUID?
    @ViewState private var confirmClear = false

    var body: some View {
        let filtered = history.filtered()
        PageScroll {
            SectionHeader("Transcripts",
                          eyebrow: countLabel,
                          subtitle: "Every dictation, with its raw text and the fixes applied.") {
                if !history.records.isEmpty {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Text("Clear All…")
                    }
                    .secondaryAction()
                }
            }

            SearchField(text: $history.search, prompt: "Search transcripts")

            if filtered.isEmpty {
                EmptyStateView(
                    icon: history.search.isEmpty ? "text.quote" : "text.magnifyingglass",
                    title: history.search.isEmpty ? "Nothing here yet" : "No matches",
                    message: history.search.isEmpty
                        ? "Your dictations will show up here."
                        : "Try a different search.",
                    actionTitle: history.search.isEmpty ? "Start recording" : nil,
                    action: history.search.isEmpty ? { NotificationCenter.default.post(name: .toggleRecord, object: nil) } : nil
                )
                .frame(minHeight: 320)
                .card(padding: nil, elevated: false)
            } else {
                ForEach(Self.dayGroups(filtered)) { group in
                    VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                        GroupLabel(group.title) {
                            Text("\(group.records.count)")
                                .font(Tokens.TypeScale.caption).monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                        GroupedList(group.records) { rec in
                            TranscriptRow(rec: rec, copied: copiedID == rec.id,
                                          timeStyle: group.showsDate ? .dateTime : .time,
                                          copyAction: { copy(rec) })
                        } menu: { rec in
                            Button("Copy") { copy(rec) }
                            Button("Copy raw") { copyRaw(rec) }
                            Divider()
                            Button("Delete", role: .destructive) { history.delete(rec) }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clear all transcripts?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear \(history.records.count) transcripts", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private var countLabel: String {
        let n = history.records.count
        return n == 1 ? "1 transcript" : "\(n.formatted()) transcripts"
    }

    /// Apple Notes' buckets: Today, Yesterday, Previous 7 Days, Previous 30
    /// Days, then one per month. Order within a bucket is preserved.
    struct DayGroup: Identifiable {
        let title: String
        let records: [TranscriptRecord]
        var id: String { title }
        /// Beyond Today and Yesterday a bare time is ambiguous.
        var showsDate: Bool { title != "Today" && title != "Yesterday" }
    }

    static func dayGroups(_ records: [TranscriptRecord]) -> [DayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let week = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let month = cal.date(byAdding: .day, value: -30, to: today) ?? today
        let monthFormat = Date.FormatStyle().month(.wide).year()

        var order: [String] = []
        var buckets: [String: [TranscriptRecord]] = [:]
        for rec in records {
            let d = rec.createdAt
            let title: String
            if d >= today { title = "Today" }
            else if d >= yesterday { title = "Yesterday" }
            else if d >= week { title = "Previous 7 Days" }
            else if d >= month { title = "Previous 30 Days" }
            else { title = d.formatted(monthFormat) }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(rec)
        }
        return order.map { DayGroup(title: $0, records: buckets[$0] ?? []) }
    }

    private func copy(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.finalText, forType: .string)
        copiedID = rec.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == rec.id { copiedID = nil } }
    }
    private func copyRaw(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.rawText, forType: .string)
    }
}

// MARK: - Dictionary

struct DictView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var dict = DictionaryStore.shared

    @ViewState private var showEditor = false
    @ViewState private var editingEntry: DictEntry?

    var body: some View {
        let filtered = dict.filtered()
        let fixes = filtered.filter { $0.kind == .correction }
        let terms = filtered.filter { $0.kind == .term }
        PageScroll {
            SectionHeader("Dictionary",
                          eyebrow: dict.entries.count == 1 ? "1 entry" : "\(dict.entries.count) entries",
                          subtitle: "Teach it the names it mishears, and fix phrases automatically.") {
                Button { addEntry() } label: { Label("Add Entry", systemImage: "plus") }
                    .primaryAction()
            }

            SearchField(text: $dict.search, prompt: "Search dictionary")

            if !dict.warnings.isEmpty { warningsBanner }

            if filtered.isEmpty {
                EmptyStateView(
                    icon: "character.book.closed",
                    title: dict.search.isEmpty ? "No entries yet" : "No matches",
                    message: dict.search.isEmpty
                        ? "Add a word to recognize, or a correction like “cloud code” → “Claude Code”."
                        : "Try a different search.",
                    actionTitle: dict.search.isEmpty ? "Add your first entry" : nil,
                    action: dict.search.isEmpty ? { addEntry() } : nil
                )
                .frame(minHeight: 320)
                .card(padding: nil, elevated: false)
            } else {
                if !fixes.isEmpty { entryGroup("Corrections", fixes) }
                if !terms.isEmpty { entryGroup("Words to recognize", terms) }
            }
        }
        .sheet(isPresented: $showEditor) {
            DictEditor(entry: editingEntry ?? DictEntry(kind: .term, phrase: "", replacement: ""),
                       onSave: { newEntry in
                           if dict.entries.contains(where: { $0.id == newEntry.id }) { dict.update(newEntry) }
                           else { dict.add(newEntry) }
                           showEditor = false
                       }, onCancel: { showEditor = false })
        }
    }

    private func entryGroup(_ title: String, _ entries: [DictEntry]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            GroupLabel(title) {
                Text("\(entries.count)")
                    .font(Tokens.TypeScale.caption).monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            GroupedList(entries, onSelect: { editEntry($0) }) { e in
                DictRow(entry: e)
            } menu: { e in
                Button("Edit") { editEntry(e) }
                Divider()
                Button("Delete", role: .destructive) { dict.remove(e) }
            }
        }
    }

    private var warningsBanner: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.Color.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(dict.warnings.count) possible conflict\(dict.warnings.count == 1 ? "" : "s")")
                    .font(Tokens.TypeScale.headline).foregroundStyle(Tokens.Color.text)
                ForEach(Array(dict.warnings.prefix(2))) { w in
                    Text(w.message)
                        .font(Tokens.TypeScale.callout).foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).strokeBorder(Tokens.Color.warn.opacity(0.18), lineWidth: 1))
    }

    private func addEntry() { editingEntry = DictEntry(kind: .term, phrase: "", replacement: ""); showEditor = true }
    private func editEntry(_ e: DictEntry) { editingEntry = e; showEditor = true }
}

/// The one in-content search field for the whole app: a recessed well with a
/// focus ring in the accent.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Color.textTert)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Color.textTert)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .frame(height: 32)
        .background(Tokens.Color.black(0.22), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(focused ? Tokens.Color.accent.opacity(0.7) : Tokens.Color.hairline,
                              lineWidth: focused ? 1.5 : 1)
        )
        .animation(Tokens.Motion.hover, value: focused)
        .frame(maxWidth: 380)
    }
}
