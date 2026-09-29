import SwiftUI
import AppKit

/// The Meetings page: record a call or a room, get a timestamped transcript and
/// minutes, keep or drop the audio — all on this Mac (spec 09).
struct MeetingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var connections = LLMConnectionStore.shared
    @ObservedObject private var modes = CustomModeStore.shared

    @ViewState private var includeSystemAudio = true
    @ViewState private var selectedID: UUID?
    @ViewState private var search = ""
    @ViewState private var titleDraft = ""
    @ViewState private var pendingDelete: MeetingSession?
    @ViewState private var pendingHostedSummary: (id: UUID, mode: CustomMode)?
    @ViewState private var copied = false

    var body: some View {
        let _ = theme.theme
        PageScroll(spacing: Tokens.Space.x6) {
            SectionHeader("Meetings", eyebrow: "Record a call or a room",
                          subtitle: "Get a timestamped transcript and minutes. The audio never leaves this Mac; minutes go wherever your AI connection points.") {
                Chip(text: ModelRegistry.shared.descriptor(for: settings.modelId).displayName,
                     systemImage: "cpu", tint: Tokens.Color.textSec, filled: false)
            }

            if store.consentAcknowledged { recordCard } else { consentCard }

            if let error = store.lastError { errorBanner(error) }

            if store.sessions.isEmpty {
                EmptyStateView(icon: "person.2.wave.2", title: "No meetings yet",
                               message: "Start a recording above. When you stop, it's transcribed here with timestamps you can click to replay.")
                    .frame(height: 260)
                    .card(padding: nil, elevated: false)
            } else {
                sessionList
            }

            if let session = selectedSession { detailCard(session) }
        }
        .alert("Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil },
                                                             set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let session = pendingDelete {
                    if selectedID == session.id { selectedID = nil }
                    store.delete(session.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The recording, the transcript and the minutes are removed. This can't be undone.")
        }
        .alert("Send this meeting to \(connections.active?.name ?? "a hosted service")?",
               isPresented: Binding(get: { pendingHostedSummary != nil },
                                    set: { if !$0 { pendingHostedSummary = nil } })) {
            Button("Send once") {
                if let pending = pendingHostedSummary {
                    Task { await store.summarize(pending.id, mode: pending.mode) }
                }
                pendingHostedSummary = nil
            }
            Button("Send and don't ask again") {
                store.hostedSummaryAcknowledged = true
                if let pending = pendingHostedSummary {
                    Task { await store.summarize(pending.id, mode: pending.mode) }
                }
                pendingHostedSummary = nil
            }
            Button("Cancel", role: .cancel) { pendingHostedSummary = nil }
        } message: {
            Text("The whole transcript leaves this Mac to be summarized at \(connections.active?.endpoint ?? "the endpoint"). A local connection (Ollama, LM Studio) keeps it here.")
        }
        .onChange(of: selectedID) { _, id in
            titleDraft = id.flatMap { store.session(id: $0)?.title } ?? ""
        }
    }

    private var selectedSession: MeetingSession? {
        selectedID.flatMap { store.session(id: $0) }
    }

    // MARK: Consent

    /// Stated once, plainly, without lecturing on every recording.
    private var consentCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(spacing: Tokens.Space.x3) {
                IconTile("hand.raised.fill", tint: Tokens.Color.warn, size: 36)
                Text("Before the first recording")
                    .font(Tokens.TypeScale.title2).foregroundStyle(Tokens.Color.text)
            }
            Text("Recording a conversation without the other people's knowledge is illegal in many places and a breach of trust everywhere else. Tell them, and get their consent — that part is on you.")
                .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.textSec)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("What NotchWhisper does: keeps the recording and the transcript on this Mac. Capturing the Mac's own audio (the other side of a call) needs the Screen Recording permission — only audio is ever read, never the screen. Minutes are written by your AI connection, local or hosted, and you're asked before a hosted one sees a meeting.")
                .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
            Button("I Understand") { store.consentAcknowledged = true }
                .primaryAction()
                .padding(.top, Tokens.Space.x1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Record

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(spacing: Tokens.Space.x4) {
                Button {
                    if store.isRecording {
                        Task { await store.stop() }
                    } else {
                        Task { await store.start(includeSystemAudio: includeSystemAudio) }
                    }
                } label: {
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: store.isRecording ? "stop.fill" : "record.circle")
                        Text(store.isRecording ? "Stop" : "Start Recording")
                    }
                }
                .primaryAction(large: true)
                .disabled(store.transcribingID != nil && !store.isRecording)

                if store.isRecording {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AudioFileImport.durationLabel(seconds: store.elapsed))
                            .font(Tokens.TypeScale.stat)
                            .foregroundStyle(Tokens.Color.text)
                        Text(store.recordingSource.label)
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    }
                    levelMeter
                } else {
                    Text("Stop to get a transcript with timestamps, then minutes.")
                        .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.textSec)
                }
                Spacer(minLength: 0)
            }

            if !store.isRecording {
                Hairline()
                HStack(alignment: .center, spacing: Tokens.Space.x3) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include the Mac's audio")
                            .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
                        Text("The other side of a call. macOS asks for the Screen Recording permission the first time — only audio is read. Off records just your microphone.")
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Tokens.Space.x4)
                    Toggle("", isOn: $includeSystemAudio).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            if let id = store.transcribingID, let session = store.session(id: id) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack {
                        Text("Transcribing \(session.title)…")
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                        Spacer()
                        Text("\(Int((store.transcribeProgress * 100).rounded()))%")
                            .font(Tokens.TypeScale.caption).monospacedDigit().foregroundStyle(Tokens.Color.textTert)
                    }
                    ProgressView(value: max(0.02, store.transcribeProgress)).tint(Tokens.Color.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Color.black(0.3))
                Capsule().fill(Tokens.Color.accent)
                    .frame(width: max(4, geo.size.width * CGFloat(store.level)))
                    .animation(.linear(duration: 0.1), value: store.level)
            }
        }
        .frame(width: 120, height: 8)
    }

    private func errorBanner(_ message: String) -> some View {
        NoticeBanner(icon: "exclamationmark.triangle.fill", title: "Something went wrong", message: message) {
            IconButton(systemImage: "xmark", help: "Dismiss") { store.lastError = nil }
        }
    }

    // MARK: Sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            GroupLabel("Recordings") {
                if store.totalAudioBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: store.totalAudioBytes, countStyle: .file)) of audio kept")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                }
            }
            VStack(spacing: 0) {
                ForEach(store.sessions) { session in
                    sessionRow(session)
                    if session.id != store.sessions.last?.id {
                        Hairline().padding(.leading, Tokens.Space.x4)
                    }
                }
            }
            .card(padding: nil, elevated: false)
        }
    }

    private func sessionRow(_ session: MeetingSession) -> some View {
        let selected = selectedID == session.id
        let dateFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
        }()
        return Button {
            withAnimation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion)) {
                selectedID = selected ? nil : session.id
            }
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                IconTile(session.id == store.recordingID ? "record.circle" : "person.2.wave.2",
                         tint: session.id == store.recordingID ? Tokens.Color.record : Tokens.Color.textSec, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(Tokens.TypeScale.body.weight(.medium)).foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                    Text("\(dateFormatter.string(from: session.startedAt)) · \(session.id == store.recordingID ? "recording" : session.durationLabel) · \(session.source.label)")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                }
                Spacer(minLength: Tokens.Space.x2)
                if session.id == store.recordingID {
                    Chip(text: "Recording", tint: Tokens.Color.record)
                } else if store.transcribingID == session.id {
                    Chip(text: "Transcribing", tint: Tokens.Color.accent)
                } else {
                    if session.interrupted { Chip(text: "Interrupted", tint: Tokens.Color.warn) }
                    if session.isTranscribed { Chip(text: "Transcript", systemImage: "text.alignleft", tint: Tokens.Color.success) }
                    if session.summary != nil { Chip(text: "Minutes", systemImage: "list.bullet", tint: Tokens.Color.accent) }
                    if !session.hasAudio { Chip(text: "Audio deleted", tint: Tokens.Color.textTert, filled: false) }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.Color.textTert)
                    .rotationEffect(.degrees(selected ? 180 : 0))
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
            .background(selected ? Tokens.Color.selectionFill.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    private func detailCard(_ session: MeetingSession) -> some View {
        let busy = store.transcribingID == session.id || store.summarizingID == session.id
            || store.recordingID == session.id
        return VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(spacing: Tokens.Space.x3) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Tokens.TypeScale.title2).foregroundStyle(Tokens.Color.text)
                    .onSubmit { store.rename(session.id, to: titleDraft) }
                Spacer(minLength: 0)
                if store.playingID == session.id {
                    Button { store.stopPlayback() } label: { Label("Stop playback", systemImage: "stop.fill") }
                        .secondaryAction()
                }
                // Destructive actions live behind "…" so the action row never
                // runs out of width and nothing is one slip from a delete.
                MoreMenu(help: "More meeting actions") {
                    if session.hasAudio, store.recordingID != session.id {
                        Button("Delete audio, keep transcript") { store.deleteAudio(session.id) }
                            .disabled(busy)
                        Divider()
                    }
                    Button("Delete Meeting…", role: .destructive) { pendingDelete = session }
                        .disabled(busy)
                }
            }

            FlowLayout(spacing: Tokens.Space.x2, lineSpacing: Tokens.Space.x2) {
                if session.hasAudio, store.recordingID != session.id {
                    Button(session.isTranscribed ? "Transcribe Again" : "Transcribe") {
                        Task { await store.transcribe(session.id) }
                    }
                    .primaryAction()
                    .disabled(busy || store.transcribingID != nil)
                }
                if session.isTranscribed {
                    Menu {
                        Button("Meeting minutes") { requestSummary(session.id, mode: MeetingStore.minutesMode) }
                        if !modes.modes.isEmpty {
                            Section("Your modes") {
                                ForEach(modes.modes) { mode in
                                    Button(mode.name) { requestSummary(session.id, mode: mode) }
                                }
                            }
                        }
                    } label: {
                        MenuLabel(session.summary == nil ? "Write Minutes" : "Rewrite Minutes",
                                  systemImage: "sparkles")
                    }
                    .secondaryMenu()
                    .disabled(busy)

                    Menu {
                        ForEach(MeetingStore.ExportFormat.allCases) { format in
                            if format != .audio || session.hasAudio {
                                Button(format.label) { store.export(session.id, as: format) }
                            }
                        }
                    } label: { MenuLabel("Export", systemImage: "square.and.arrow.up") }
                    .secondaryMenu()

                    Button(copied ? "Copied" : "Copy Transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.markdownExport, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    }
                    .secondaryAction()
                }
            }

            if store.summarizingID == session.id {
                HStack(spacing: Tokens.Space.x2) {
                    ProgressView().controlSize(.small)
                    Text("Writing minutes with \(connections.active?.name ?? "the AI connection")…")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                }
            }

            if let summary = session.summary {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    MarkdownLite(summary.markdown)
                    Text("Minutes by \(summary.generatedBy)")
                        .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                }
                .padding(Tokens.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Color.black(0.2), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            }

            if session.isTranscribed {
                transcriptView(session)
            } else if store.transcribingID != session.id, store.recordingID != session.id {
                Text(session.hasAudio
                     ? "Not transcribed yet."
                     : "The audio was deleted before this meeting was transcribed.")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func requestSummary(_ id: UUID, mode: CustomMode) {
        if let connection = connections.active, !connection.isLocal, !store.hostedSummaryAcknowledged {
            pendingHostedSummary = (id, mode)
            return
        }
        Task { await store.summarize(id, mode: mode) }
    }

    private func transcriptView(_ session: MeetingSession) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = query.isEmpty ? session.segments
            : session.segments.filter { $0.text.lowercased().contains(query) }
        return VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack {
                Text("Transcript")
                    .font(Tokens.TypeScale.headline).foregroundStyle(Tokens.Color.text)
                Spacer()
                SearchField(text: $search, prompt: "Search this meeting")
                    .frame(maxWidth: 240)
            }
            if lines.isEmpty {
                Text("Nothing matches \"\(search)\".")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: Tokens.Space.x2) {
                        Button {
                            store.play(session.id, from: line.start)
                        } label: {
                            Text(line.timestampLabel)
                                .font(Tokens.TypeScale.caption).monospacedDigit()
                                .foregroundStyle(session.hasAudio ? Tokens.Color.accent : Tokens.Color.textTert)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.hasAudio)
                        .help(session.hasAudio ? "Play from here" : "Audio deleted")
                        Text(line.text)
                            .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.textSec)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Markdown (light)

/// Enough Markdown for minutes: headings, bullets, checklists, paragraphs.
/// Inline emphasis goes through `AttributedString`; anything else is text.
struct MarkdownLite: View {
    let source: String

    init(_ source: String) { self.source = source }

    private enum Block { case heading(String), bullet(String, checked: Bool?), paragraph(String), blank }

    private var blocks: [Block] {
        source.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .blank }
            if line.hasPrefix("#") {
                return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            for marker in ["- [ ] ", "* [ ] "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)), checked: false)
            }
            for marker in ["- [x] ", "* [x] ", "- [X] ", "* [X] "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)), checked: true)
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)), checked: nil)
            }
            return .paragraph(line)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) { return Text(attributed) }
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.text)
                        .padding(.top, 6)
                case .bullet(let text, let checked):
                    HStack(alignment: .top, spacing: 6) {
                        if let checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                                .font(.system(size: 11)).foregroundStyle(Tokens.Color.accent)
                        } else {
                            Text("•").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                        }
                        inline(text)
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let text):
                    inline(text)
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                case .blank:
                    Spacer().frame(height: 2)
                }
            }
        }
        .textSelection(.enabled)
    }
}
