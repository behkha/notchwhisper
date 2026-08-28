import SwiftUI
import AVFoundation

/// The main application window. A sidebar navigates between Home, Transcripts,
/// Dictionary and Models; a Settings button at the bottom of the sidebar opens
/// the Settings window. Everything reads from Tokens.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @State private var nav: Nav? = .home

    enum Nav: String, CaseIterable, Identifiable {
        case home, transcripts, dictionary, models
        var id: String { rawValue }
        var label: String {
            switch self {
            case .home:       return "Home"
            case .transcripts: return "Transcripts"
            case .dictionary:  return "Dictionary"
            case .models:      return "Models"
            }
        }
        var icon: String {
            switch self {
            case .home:       return "house.fill"
            case .transcripts: return "doc.text.fill"
            case .dictionary:  return "book.closed.fill"
            case .models:      return "cpu.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(minWidth: Tokens.Layout.minWinW, maxWidth: Tokens.Layout.maxWinW,
               minHeight: Tokens.Layout.minWinH, maxHeight: Tokens.Layout.maxWinH)
        .background(Tokens.Color.bg)
    }

    // MARK: - Sidebar
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $nav) {
                ForEach(Nav.allCases) { item in
                    Label(item.label, systemImage: item.icon)
                        .font(Tokens.TypeScale.headline)
                        .tag(item)
                        .listItemTint(Tokens.Color.accent)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)

            Divider().foregroundStyle(Tokens.Color.separator)

            // Settings button (req 4)
            Button {
                AppDelegate.shared?.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(Tokens.TypeScale.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
            .help("Open Settings (⌘,)")
        }
        .frame(width: Tokens.Layout.sidebarW)
        .background(Tokens.Color.bg)
    }

    // MARK: - Detail
    @ViewBuilder
    private var detailView: some View {
        switch nav {
        case .home:       HomeView(nav: $nav).environmentObject(state).environmentObject(settings)
        case .transcripts: TranscriptsView().environmentObject(state).environmentObject(settings)
        case .dictionary:  DictView().environmentObject(state).environmentObject(settings)
        case .models:      ModelsView().environmentObject(state).environmentObject(settings)
        case .none:        HomeView(nav: $nav).environmentObject(state).environmentObject(settings)
        }
    }
}

// MARK: - Home (req 5)
/// Default landing page: live record control, usage statistics, and recent history.
struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @Binding var nav: MainView.Nav?

    @State private var copiedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                header
                statsGrid
                recentSection
            }
            .padding(Tokens.Space.x6)
        }
        .background(Tokens.Color.bg)
    }

    // MARK: Record control
    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(alignment: .center, spacing: Tokens.Space.x4) {
                LevelsMeter(height: 44)
                    .frame(width: Tokens.Layout.meterW)
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack(spacing: Tokens.Space.x2) {
                        statusDot
                        Text(statusText)
                            .font(Tokens.TypeScale.callout)
                            .foregroundStyle(Tokens.Color.textSec)
                    }
                    if state.mode == .recording, let start = state.recordingStart {
                        Text("Recording \(fmt(Date().timeIntervalSince(start)))")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                            .monospacedDigit()
                    } else if state.mode == .transcribing {
                        Text("Transcribing…")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                Spacer(minLength: Tokens.Space.x4)
                RecordButton(action: toggleRecord)
            }
            Text("Hold \(settings.hotkeyDisplay) anywhere to talk — or tap Record.")
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.accent)
                .padding(.top, Tokens.Space.x1)

            // One-click current model + language (ChatGPT rec)
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "cpu")
                    .font(.system(size: 12)).foregroundStyle(Tokens.Color.textTert)
                Text("\(WhisperModelOption.find(id: settings.modelId).display) · \(WhisperModelOption.find(id: settings.modelId).lang)")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Button { nav = MainView.Nav.models } label: {
                    Text("Change").font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.accent)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, Tokens.Space.x1)

            // Health row (ChatGPT rec): model / mic / dictionary
            healthRow
                .padding(.top, Tokens.Space.x1)
        }
        .padding(Tokens.Space.x4)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    /// Compact status chips: model ready, microphone permission, dictionary active.
    private var healthRow: some View {
        HStack(spacing: Tokens.Space.x3) {
            healthChip(ok: state.modelStatus == .ready,
                       okLabel: "Model ready", pendingLabel: "Model loading…")
            healthChip(ok: micAuthorized,
                       okLabel: "Mic allowed", pendingLabel: "Mic blocked")
            healthChip(ok: !DictionaryStore.shared.entries.isEmpty,
                       okLabel: "Dictionary on", pendingLabel: "No dictionary")
            Spacer(minLength: 0)
        }
    }

    private func healthChip(ok: Bool, okLabel: String, pendingLabel: String) -> some View {
        HStack(spacing: Tokens.Space.x1) {
            Circle().fill(ok ? Tokens.Color.success : Tokens.Color.warn)
                .frame(width: 7, height: 7)
            Text(ok ? okLabel : pendingLabel)
                .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
            .animation(Tokens.Motion.quick, value: dotColor)
    }
    private var dotColor: SwiftUI.Color {
        switch state.mode {
        case .idle:        return Tokens.Color.textTert
        case .recording:   return Tokens.Color.record
        case .transcribing: return Tokens.Color.warn
        case .done:        return Tokens.Color.success
        case .error:       return Tokens.Color.danger
        }
    }
    private var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var statusText: String {
        switch state.mode {
        case .idle:
            switch state.modelStatus {
            case .ready: return "Ready"
            case .loading, .downloading: return "Loading model…"
            case .error(let e): return "Model error: \(e)"
            case .unknown: return "Starting…"
            }
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing…"
        case .done:         return "Done"
        case .error:        return state.statusMessage.isEmpty ? "Error" : state.statusMessage
        }
    }

    // MARK: Statistics
    private var statsGrid: some View {
        let stats = computeStats()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Space.x4)], spacing: Tokens.Space.x4) {
            StatCard(title: "Transcripts", value: "\(stats.total)", icon: "doc.text.fill")
            StatCard(title: "Today", value: "\(stats.today)", icon: "calendar")
            StatCard(title: "Words", value: stats.words, icon: "character.book.closed")
            StatCard(title: "Dictionary fixes", value: "\(stats.corrections)", icon: "wand.and.stars")
            StatCard(title: "Active model", value: WhisperModelOption.find(id: settings.modelId).display, icon: "cpu")
            StatCard(title: "This week", value: "\(stats.week)", icon: "chart.bar.fill")
        }
    }

    // MARK: Recent transcripts
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("Recent")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
            if history.records.isEmpty {
                Text("No transcripts yet. Hold \(settings.hotkeyDisplay) and speak.")
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textTert)
                    .padding(Tokens.Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            } else {
                VStack(spacing: Tokens.Space.x2) {
                    ForEach(Array(history.records.prefix(5))) { rec in
                        TranscriptRow(rec: rec, copied: copiedID == rec.id)
                            .listRowBackground(Tokens.Color.surface)
                            .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                            .contextMenu {
                                Button("Copy") { copy(rec) }
                                Button("Copy Raw") { copyRaw(rec) }
                                Divider()
                                Button("Delete", role: .destructive) { history.delete(rec) }
                            }
                    }
                }
            }
        }
    }

    // MARK: Stats computation
    private func computeStats() -> (total: Int, today: Int, week: Int, words: String, corrections: Int) {
        let recs = history.records
        let total = recs.count
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let today = recs.filter { $0.createdAt >= startOfToday }.count
        let week = recs.filter { $0.createdAt >= startOfWeek }.count
        let wordCount = recs.reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace }).count }
        let corrections = recs.reduce(0) { $0 + $1.corrections.count }
        return (total, today, week, wordCount.formatted(), corrections)
    }

    // MARK: Actions
    private func toggleRecord() {
        NotificationCenter.default.post(name: .toggleRecord, object: nil)
    }
    private func copy(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.finalText, forType: .string)
        copiedID = rec.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == rec.id { copiedID = nil }
        }
    }
    private func copyRaw(_ rec: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rec.rawText, forType: .string)
    }
}

/// A small statistic tile for the Home page.
struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.Color.accent)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(Tokens.TypeScale.title1)
                .foregroundStyle(Tokens.Color.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }
}

// MARK: - Transcripts (moved to sidebar, req 3)
struct TranscriptsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @State private var selected: UUID?
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Color.textTert)
                TextField("Search transcripts", text: $history.search)
                    .textFieldStyle(.plain).font(Tokens.TypeScale.body)
                if !history.search.isEmpty {
                    Button { history.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Color.textTert)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button { history.clear() } label: { Text("Clear").font(Tokens.TypeScale.caption) }
                    .buttonStyle(.plain).foregroundStyle(Tokens.Color.textSec)
            }
            .padding(.horizontal, Tokens.Space.x4).padding(.vertical, Tokens.Space.x2)
            Divider().foregroundStyle(Tokens.Color.separator)

            if history.filtered().isEmpty {
                emptyState
            } else {
                List(selection: $selected) {
                    ForEach(history.filtered()) { rec in
                        TranscriptRow(rec: rec, copied: copiedID == rec.id)
                            .tag(rec.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Tokens.Space.x2, leading: Tokens.Space.x3,
                                                      bottom: Tokens.Space.x2, trailing: Tokens.Space.x3))
                            .listRowBackground(Tokens.Color.surface)
                            .contextMenu {
                                Button("Copy") { copy(rec) }
                                Button("Copy Raw") { copyRaw(rec) }
                                Divider()
                                Button("Delete", role: .destructive) { history.delete(rec) }
                            }
                            .onTapGesture { selected = rec.id }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background(Tokens.Color.bg)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Space.x3) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundStyle(Tokens.Color.textTert)
            Text(history.search.isEmpty ? "No transcripts yet." : "No matches for “\(history.search)”.")
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textTert)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.bg)
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

// MARK: - Dictionary (moved to sidebar, req 3)
struct DictView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var dict = DictionaryStore.shared

    @State private var showEditor = false
    @State private var editingEntry: DictEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Color.textTert)
                TextField("Search dictionary", text: $dict.search)
                    .textFieldStyle(.plain).font(Tokens.TypeScale.body)
                if !dict.search.isEmpty {
                    Button { dict.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Color.textTert)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button { addEntry() } label: {
                    Label("Add", systemImage: "plus").font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.Color.accent)
            }
            .padding(.horizontal, Tokens.Space.x4).padding(.vertical, Tokens.Space.x2)

            if !dict.warnings.isEmpty { warningsBanner }

            Divider().foregroundStyle(Tokens.Color.separator)

            if dict.filtered().isEmpty {
                VStack(spacing: Tokens.Space.x3) {
                    Spacer()
                    Image(systemName: "book.closed")
                        .font(.system(size: 36)).foregroundStyle(Tokens.Color.textTert)
                    Text("No entries yet. Add a term or a correction — e.g. “cloud code” → “Claude Code”.")
                        .font(Tokens.TypeScale.callout).foregroundStyle(Tokens.Color.textTert)
                        .multilineTextAlignment(.center).padding(.horizontal, Tokens.Space.x6)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.Color.bg)
            } else {
                List {
                    ForEach(dict.filtered()) { e in
                        DictRow(entry: e)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Tokens.Space.x2, leading: Tokens.Space.x3,
                                                      bottom: Tokens.Space.x2, trailing: Tokens.Space.x3))
                            .listRowBackground(Tokens.Color.surface)
                            .contextMenu {
                                Button("Edit") { editEntry(e) }
                                Divider()
                                Button("Delete", role: .destructive) { dict.remove(e) }
                            }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background(Tokens.Color.bg)
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

    private var warningsBanner: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Color.warn)
                Text("\(dict.warnings.count) possible conflict\(dict.warnings.count == 1 ? "" : "s")")
                    .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.warn)
                Spacer()
            }
            ForEach(dict.warnings.prefix(2)) { w in
                Text("• " + w.message)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Space.x3)
        .background(Tokens.Color.warn.opacity(0.12))
    }

    private func addEntry() { editingEntry = DictEntry(kind: .term, phrase: "", replacement: ""); showEditor = true }
    private func editEntry(_ e: DictEntry) { editingEntry = e; showEditor = true }
}

private func fmt(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}
