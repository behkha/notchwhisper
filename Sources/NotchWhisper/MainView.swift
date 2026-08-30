import SwiftUI
import AVFoundation

/// The main window shell — a bespoke sidebar + detail layout on the Aurora
/// canvas (no `NavigationSplitView`, no system list chrome). Nav lives in a
/// custom rail with a sliding selection pill; each screen is a scroll of glass
/// cards.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @State private var nav: Nav = .home
    @Namespace private var pill

    enum Nav: String, CaseIterable, Identifiable {
        case home, transcripts, dictionary, models
        var id: String { rawValue }
        var label: String {
            switch self {
            case .home: return "Home"
            case .transcripts: return "Transcripts"
            case .dictionary: return "Dictionary"
            case .models: return "Models"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .transcripts: return "text.line.first.and.arrowtriangle.forward"
            case .dictionary: return "character.book.closed.fill"
            case .models: return "cpu.fill"
            }
        }
    }

    var body: some View {
        let _ = theme.theme
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Tokens.Color.hairline).frame(width: 1).ignoresSafeArea()
            detail
        }
        .frame(minWidth: Tokens.Layout.minWinW, maxWidth: Tokens.Layout.maxWinW,
               minHeight: Tokens.Layout.minWinH, maxHeight: Tokens.Layout.maxWinH)
        .background(AuroraBackground())
        .tint(Tokens.Color.accent)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wordmark
            HStack(spacing: Tokens.Space.x2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Tokens.Color.accentGradient)
                        .frame(width: 26, height: 26)
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Tokens.Color.onAccent)
                }
                Text("NotchWhisper")
                    .font(Tokens.TypeScale.title2)
                    .foregroundStyle(Tokens.Color.text)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.top, Tokens.Space.x4)
            .padding(.bottom, Tokens.Space.x6)

            // Nav
            VStack(spacing: 2) {
                ForEach(Nav.allCases) { item in
                    navItem(item)
                }
            }
            .padding(.horizontal, Tokens.Space.x3)

            Spacer()

            healthCard
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.bottom, Tokens.Space.x2)

            Button {
                AppDelegate.shared?.showSettings()
            } label: {
                HStack(spacing: Tokens.Space.x3) {
                    IconTile("gearshape.fill", tint: Tokens.Color.textSec, size: 24)
                    Text("Settings")
                        .font(Tokens.TypeScale.body.weight(.medium))
                        .foregroundStyle(Tokens.Color.text)
                    Spacer()
                    Text("⌘,").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                }
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, Tokens.Space.x2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.bottom, Tokens.Space.x4)
        }
        .frame(width: Tokens.Layout.sidebarW)
    }

    private func navItem(_ item: Nav) -> some View {
        let selected = nav == item
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { nav = item }
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Tokens.Color.accent : Tokens.Color.textSec)
                    .frame(width: 22)
                Text(item.label)
                    .font(Tokens.TypeScale.body.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Tokens.Color.text : Tokens.Color.textSec)
                Spacer()
            }
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.Color.accent.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .strokeBorder(Tokens.Color.accent.opacity(0.2), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "navpill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            healthLine(ok: state.modelStatus == .ready,
                       label: state.modelStatus == .ready ? "Model ready" : "Model loading")
            healthLine(ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                       label: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Microphone" : "Mic blocked")
            healthLine(ok: AutoTyper.isTrusted, label: AutoTyper.isTrusted ? "Accessibility" : "Accessibility off")
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
    }

    private func healthLine(ok: Bool, label: String) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Tokens.Color.success : Tokens.Color.warn)
            Text(label)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textSec)
            Spacer(minLength: 0)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch nav {
            case .home:        HomeView(nav: $nav)
            case .transcripts: TranscriptsView()
            case .dictionary:  DictView()
            case .models:      ModelsView()
            }
        }
        .environmentObject(state)
        .environmentObject(settings)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var history = HistoryStore.shared
    @Binding var nav: MainView.Nav

    @State private var copiedID: UUID?

    var body: some View {
        let _ = theme.theme
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                SectionHeader("Speak, and it types.", eyebrow: greeting) {
                    Chip(text: state.modelStatus == .ready ? "Ready" : "Loading",
                         tint: state.modelStatus == .ready ? Tokens.Color.success : Tokens.Color.warn)
                }

                heroCard

                if state.isDownloading || state.isLoadingModel { modelProgressCard }

                statsStrip

                recentSection
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
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

    private var heroCard: some View {
        VStack(spacing: Tokens.Space.x5) {
            HStack(alignment: .center, spacing: Tokens.Space.x5) {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    HStack(spacing: Tokens.Space.x2) {
                        statusDot
                        Text(statusText)
                            .font(Tokens.TypeScale.title2)
                            .foregroundStyle(Tokens.Color.text)
                    }
                    Text(settings.liveDictation
                         ? "Press \(settings.hotkeyDisplay) to start live dictation — press again to stop. Words appear as you speak."
                         : "Hold \(settings.hotkeyDisplay) anywhere and talk. Release to transcribe and type.")
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Tokens.Space.x2) {
                        Chip(text: WhisperModelOption.find(id: settings.modelId).display,
                             systemImage: "cpu", tint: Tokens.Color.accent)
                        Chip(text: settings.liveDictation ? "Live dictation" : "Hold to talk",
                             systemImage: settings.liveDictation ? "dot.radiowaves.left.and.right" : "hand.tap",
                             tint: Tokens.Color.textSec, filled: false)
                        Button {
                            AppDelegate.shared?.showSettings()
                        } label: {
                            Text("Change").font(Tokens.TypeScale.micro)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.Color.accent)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: Tokens.Space.x4)
                RecordButton(action: toggleRecord)
            }

            LevelsMeter(height: 56)
        }
        .card()
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .shadow(color: (state.mode == .recording || state.mode == .dictating)
                    ? Tokens.Color.record.opacity(0.7) : .clear, radius: 4)
            .overlay(
                Circle().stroke(dotColor.opacity(0.35), lineWidth: 4)
                    .scaleEffect(state.mode == .recording ? 1.8 : 1)
                    .opacity(state.mode == .recording ? 0 : 0)
            )
            .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: state.mode)
    }
    private var dotColor: SwiftUI.Color {
        switch state.mode {
        case .idle: return Tokens.Color.textTert
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
            case .unknown: return "Starting up…"
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
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                ProgressView().controlSize(.small)
                Text(state.isDownloading
                     ? (state.downloadLabel.isEmpty ? "Downloading model…" : state.downloadLabel)
                     : (state.modelLoadPhase.isEmpty ? "Loading model…" : state.modelLoadPhase))
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                Text("\(Int(((state.isDownloading ? state.displayProgress : state.modelLoadProgress) * 100).rounded()))%")
                    .font(Tokens.TypeScale.callout).monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            ProgressView(value: max(state.isDownloading ? state.displayProgress : state.modelLoadProgress, 0.02))
                .tint(Tokens.Color.accent)
            if state.isDownloading, !state.downloadDetailText.isEmpty {
                Text(state.downloadDetailText)
                    .font(Tokens.TypeScale.caption).monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
        }
        .card(radius: Tokens.Radius.md)
    }

    // MARK: Stats

    private var statsStrip: some View {
        let s = computeStats()
        return VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("YOUR ACTIVITY")
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Space.x3)],
                      spacing: Tokens.Space.x3) {
                StatCard(title: "Transcripts", value: "\(s.total)", icon: "text.quote")
                StatCard(title: "Today", value: "\(s.today)", icon: "sun.max")
                StatCard(title: "This week", value: "\(s.week)", icon: "calendar")
                StatCard(title: "Words dictated", value: s.words, icon: "textformat.abc")
                StatCard(title: "Dictionary fixes", value: "\(s.corrections)", icon: "wand.and.sparkles")
                StatCard(title: "Active model", value: WhisperModelOption.find(id: settings.modelId).display, icon: "cpu")
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack {
                Text("RECENT")
                    .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer()
                if !history.records.isEmpty {
                    Button("See all") { nav = .transcripts }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                }
            }
            if history.records.isEmpty {
                EmptyStateView(
                    icon: "waveform",
                    title: "No transcripts yet",
                    message: settings.liveDictation
                        ? "Press \(settings.hotkeyDisplay), speak, then press again to stop."
                        : "Hold \(settings.hotkeyDisplay) anywhere and start talking."
                )
                .frame(height: 220)
                .card(padding: nil)
            } else {
                VStack(spacing: Tokens.Space.x2) {
                    ForEach(Array(history.records.prefix(4))) { rec in
                        TranscriptRow(rec: rec, copied: copiedID == rec.id, copyAction: { copy(rec) })
                            .padding(Tokens.Space.x3)
                            .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
                            .contextMenu {
                                Button("Copy") { copy(rec) }
                                Button("Copy raw") { copyRaw(rec) }
                                Divider()
                                Button("Delete", role: .destructive) { history.delete(rec) }
                            }
                    }
                }
            }
        }
    }

    private func computeStats() -> (total: Int, today: Int, week: Int, words: String, corrections: Int) {
        let recs = history.records
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? startOfToday
        let today = recs.filter { $0.createdAt >= startOfToday }.count
        let week = recs.filter { $0.createdAt >= startOfWeek }.count
        let wordCount = recs.reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace }).count }
        let corrections = recs.reduce(0) { $0 + $1.corrections.count }
        return (recs.count, today, week, wordCount.formatted(), corrections)
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

/// A minimal stat cell.
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    var body: some View {
        let _ = theme.theme
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.accent)
            Text(value)
                .font(Tokens.TypeScale.title1)
                .foregroundStyle(Tokens.Color.text)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(title)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
    }
}

// MARK: - Transcripts

struct TranscriptsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @State private var copiedID: UUID?
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                SectionHeader("Transcripts",
                              eyebrow: "\(history.records.count) saved",
                              subtitle: "Every dictation, with its raw text and dictionary fixes.") {
                    if !history.records.isEmpty {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear all", systemImage: "trash")
                        }
                        .secondaryAction()
                    }
                }

                SearchField(text: $history.search, prompt: "Search transcripts")

                if history.filtered().isEmpty {
                    EmptyStateView(
                        icon: "text.magnifyingglass",
                        title: history.search.isEmpty ? "Nothing here yet" : "No matches",
                        message: history.search.isEmpty
                            ? "Your dictations will show up here."
                            : "Try a different search.",
                        actionTitle: history.search.isEmpty ? "Start recording" : nil,
                        action: history.search.isEmpty ? { NotificationCenter.default.post(name: .toggleRecord, object: nil) } : nil
                    )
                    .frame(minHeight: 320)
                    .card(padding: nil)
                } else {
                    VStack(spacing: Tokens.Space.x2) {
                        ForEach(history.filtered()) { rec in
                            TranscriptRow(rec: rec, copied: copiedID == rec.id, copyAction: { copy(rec) })
                                .padding(Tokens.Space.x3)
                                .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
                                .contextMenu {
                                    Button("Copy") { copy(rec) }
                                    Button("Copy raw") { copyRaw(rec) }
                                    Divider()
                                    Button("Delete", role: .destructive) { history.delete(rec) }
                                }
                        }
                    }
                }
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .confirmationDialog("Clear all transcripts?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear \(history.records.count) transcripts", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
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

    @State private var showEditor = false
    @State private var editingEntry: DictEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                SectionHeader("Dictionary",
                              eyebrow: "\(dict.entries.count) entries",
                              subtitle: "Teach it names it mishears, and fix phrases automatically.") {
                    Button { addEntry() } label: { Label("Add entry", systemImage: "plus") }
                        .primaryAction()
                }

                SearchField(text: $dict.search, prompt: "Search dictionary")

                if !dict.warnings.isEmpty { warningsBanner }

                if dict.filtered().isEmpty {
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
                    .card(padding: nil)
                } else {
                    VStack(spacing: Tokens.Space.x2) {
                        ForEach(dict.filtered()) { e in
                            DictRow(entry: e)
                                .padding(Tokens.Space.x3)
                                .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
                                .onTapGesture { editEntry(e) }
                                .contextMenu {
                                    Button("Edit") { editEntry(e) }
                                    Divider()
                                    Button("Delete", role: .destructive) { dict.remove(e) }
                                }
                        }
                    }
                }
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showEditor) {
            DictEditor(entry: editingEntry ?? DictEntry(kind: .term, phrase: "", replacement: ""),
                       onSave: { newEntry in
                           if dict.entries.contains(where: { $0.id == newEntry.id }) { dict.update(newEntry) }
                           else { dict.add(newEntry) }
                           showEditor = false
                       }, onCancel: { showEditor = false })
        }
    }

    private var warningsBanner: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Color.warn)
                Text("\(dict.warnings.count) possible conflict\(dict.warnings.count == 1 ? "" : "s")")
                    .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.warn)
                Spacer()
            }
            ForEach(Array(dict.warnings.prefix(2))) { w in
                Text("• " + w.message)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            }
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Color.warn.opacity(0.25), lineWidth: 1))
    }

    private func addEntry() { editingEntry = DictEntry(kind: .term, phrase: "", replacement: ""); showEditor = true }
    private func editEntry(_ e: DictEntry) { editingEntry = e; showEditor = true }
}

/// The one in-content search field for the whole app.
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Color.textTert)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Color.textTert)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Space.x3)
        .padding(.vertical, 9)
        .background(Tokens.Color.fillQuiet, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .frame(maxWidth: 420)
    }
}
