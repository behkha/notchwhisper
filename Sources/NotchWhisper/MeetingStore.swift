import Foundation
import AppKit
import AVFoundation

// MARK: - Model

/// One timestamped line of a meeting transcript.
struct MeetingSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Which side of the conversation. v1 transcribes the mix; the field is
    /// the seam diarization needs later.
    var channel: Channel = .mixed

    enum Channel: String, Codable { case mic, system, mixed }

    var timestampLabel: String { AudioFileImport.durationLabel(seconds: start) }
}

/// The minutes produced by the LLM pass. Kept as Markdown: sections the model
/// wrote, rendered lightly, exported verbatim.
struct MeetingSummary: Codable, Hashable {
    var markdown: String
    /// Connection and model, for provenance.
    var generatedBy: String
    var generatedAt: Date
}

struct MeetingSession: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    /// Relative to the Meetings directory; nil once the audio was deleted.
    var audioFile: String?
    var audioBytes: Int64 = 0
    var source: MeetingRecorder.Source = .micOnly
    var segments: [MeetingSegment] = []
    var summary: MeetingSummary? = nil
    var modelId: String? = nil
    /// The app stopped (crashed, quit, slept) before the recording was ended
    /// properly. The file is still playable up to its last header flush.
    var interrupted: Bool = false

    var isTranscribed: Bool { !segments.isEmpty }
    var hasAudio: Bool { audioFile != nil }

    var durationLabel: String { AudioFileImport.durationLabel(seconds: duration) }

    var transcriptText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// "[12:04] text" lines — what the LLM and the exports see.
    var timestampedTranscript: String {
        segments.map { "[\($0.timestampLabel)] \($0.text)" }.joined(separator: "\n")
    }

    /// The export people paste into Notion, Obsidian or a ticket.
    var markdownExport: String {
        var out = "# \(title)\n\n"
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        out += "\(formatter.string(from: startedAt)) · \(durationLabel) · \(source.label)\n\n"
        if let summary {
            out += summary.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            out += "_Minutes by \(summary.generatedBy)._\n\n"
        }
        out += "## Transcript\n\n"
        out += segments.isEmpty ? "_Not transcribed yet._\n" : timestampedTranscript + "\n"
        return out
    }
}

// MARK: - Transcription

/// The chunked, silence-gated, timestamped decode shared by the Meetings page
/// and `--meeting-selftest`: 30 s windows with a 2 s overlap, each window
/// skipped when it carries no speech (a meeting is mostly silence from any one
/// channel's point of view), timestamps offset by window position.
@MainActor enum MeetingTranscription {
    struct Result {
        var segments: [MeetingSegment] = []
        var failure: String? = nil
    }

    static let windowSeconds = 30
    static let overlapSeconds = 2

    static func run(samples: [Float], transcriber: Transcriber,
                    sensitivity: VoiceActivityDetector.Sensitivity, trimSilence: Bool,
                    biasTerms: [String], onProgress: @escaping (Double) -> Void) async -> Result {
        let rate = Int(MeetingRecorder.sampleRate)
        let window = windowSeconds * rate
        let step = window - overlapSeconds * rate
        let detector = VoiceActivityDetector(sensitivity: sensitivity)
        var result = Result()
        var position = 0
        var lastEnd: TimeInterval = 0
        while position < samples.count {
            var end = min(samples.count, position + window)
            var chunk = Array(samples[position..<end])
            let offset = Double(position) / Double(rate)
            var analysis = await Task.detached(priority: .userInitiated) { detector.analyse(chunk) }.value
            var advance = step
            // End the window in a pause when there is one, so no word is
            // split across two decodes; then the next window starts exactly
            // there and no overlap is needed. The fixed overlap is the
            // fallback for a tail with no pause in it.
            if end < samples.count,
               let cut = detector.quietCut(chunk, noiseFloor: analysis.noiseFloor),
               cut > overlapSeconds * rate {
                end = position + cut
                chunk = Array(chunk[0..<cut])
                analysis = detector.analyse(chunk)
                advance = cut
            }
            let windowEnd = Double(end) / Double(rate)
            let isLastWindow = end == samples.count
            if analysis.hasSpeech {
                let clip = trimSilence ? detector.trimmed(chunk, analysis: analysis) : chunk
                let clipOffset = clip.count == chunk.count
                    ? offset
                    : offset + Double(max(0, analysis.leadingSilence - VoiceActivityDetector.paddingSamples)) / Double(rate)
                do {
                    let found = try await transcriber.transcribeTimed(clip, biasTerms: biasTerms)
                    for piece in found {
                        let start = clipOffset + piece.start
                        let stop = clipOffset + piece.end
                        // The overlap re-decodes the previous window's tail;
                        // anything that ends inside what is already written,
                        // or started well inside it, is that tail.
                        guard stop > lastEnd + 0.3, start >= lastEnd - 1.0 else { continue }
                        // A sentence cut by this window's edge comes out
                        // garbled ("Nobody was sure, so…" → "Nobody was
                        // showing up."). When it began inside the overlap the
                        // next window decodes it whole, so leave it to that one.
                        if !isLastWindow, stop >= windowEnd - 0.5,
                           start >= windowEnd - Double(overlapSeconds) - 0.5 { continue }
                        let text = DictionaryStore.shared.applyCorrections(piece.text).0
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty,
                              !VoiceActivityDetector.isLikelyHallucination(text, analysis: analysis) else { continue }
                        result.segments.append(MeetingSegment(start: max(start, lastEnd), end: stop, text: text))
                        lastEnd = stop
                    }
                } catch {
                    result.failure = "Transcription stopped at \(AudioFileImport.durationLabel(seconds: offset)): \(error.localizedDescription)"
                    break
                }
            }
            position += advance
            onProgress(min(1, Double(position) / Double(samples.count)))
        }
        return result
    }
}

// MARK: - Store

/// Meetings: the sessions, the one recording in flight, and the pipeline that
/// turns a recording into a timestamped transcript and minutes. Same shape as
/// every other store — JSON under Application Support, silent-failure
/// persistence — plus one directory per meeting for the audio.
@MainActor final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var sessions: [MeetingSession] = []

    // Recording in flight
    @Published private(set) var recordingID: UUID?
    @Published private(set) var recordingSource: MeetingRecorder.Source = .micOnly
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    // Post-processing in flight
    @Published private(set) var transcribingID: UUID?
    @Published private(set) var transcribeProgress: Double = 0
    @Published private(set) var summarizingID: UUID?

    // Playback
    @Published private(set) var playingID: UUID?

    /// Last problem, shown on the page until the next action clears it.
    @Published var lastError: String?

    /// The one-time consent explainer was acknowledged.
    @Published var consentAcknowledged: Bool {
        didSet { UserDefaults.standard.set(consentAcknowledged, forKey: Self.consentKey) }
    }
    /// The user confirmed sending a meeting to a hosted endpoint once.
    @Published var hostedSummaryAcknowledged: Bool {
        didSet { UserDefaults.standard.set(hostedSummaryAcknowledged, forKey: Self.hostedKey) }
    }

    private static let consentKey = "meetingConsentAcknowledged"
    private static let hostedKey = "meetingHostedSummaryAcknowledged"

    /// Refuse to start with less than this free — a long meeting is hundreds
    /// of megabytes and a disk-full stop loses the end of it.
    static let minimumFreeBytes: Int64 = 2 * 1_073_741_824

    let recorder = MeetingRecorder()
    private var elapsedTimer: Timer?
    private var player: AVAudioPlayer?
    private let fileManager = FileManager.default

    var isRecording: Bool { recordingID != nil }

    var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/Meetings", isDirectory: true)
    }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        consentAcknowledged = UserDefaults.standard.bool(forKey: Self.consentKey)
        hostedSummaryAcknowledged = UserDefaults.standard.bool(forKey: Self.hostedKey)
        load()
        reconcileInterrupted()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        recorder.onNotice = { [weak self] notice in
            Task { @MainActor in self?.lastError = notice }
        }
    }

    // MARK: Queries

    func session(id: UUID) -> MeetingSession? { sessions.first { $0.id == id } }

    func audioURL(for session: MeetingSession) -> URL? {
        session.audioFile.map { directory.appendingPathComponent($0) }
    }

    /// The minutes mode meetings ship with. Runs through the ordinary mode
    /// pipeline (map-reduce over long transcripts) without being stored, so
    /// the user's own mode list stays theirs.
    nonisolated static let minutesMode = CustomMode(
        name: "Meeting Minutes",
        instructions: """
        Turn this meeting transcript into minutes.
        Use these Markdown headings, in this order: Overview (two to four sentences), Decisions (bullets), Action items (a checklist, with the owner and deadline when they were mentioned), Topics (bullets), Open questions (bullets; leave the section out if there are none).
        Only include what is in the transcript. Keep names, numbers and dates exactly as said. Write in the language of the transcript.
        """,
        symbolName: "person.3",
        creativity: .precise,
        singleDocument: true
    )

    // MARK: Recording

    /// Starts a meeting. The session is written to the index immediately as
    /// `interrupted`, so a crash still leaves a recoverable entry.
    func start(includeSystemAudio: Bool) async {
        guard !isRecording else { return }
        lastError = nil
        let state = AppState.shared
        guard state.mode == .idle || state.mode == .done || state.mode == .error else {
            lastError = "Finish the current dictation first — it's using the microphone."
            return
        }
        guard !state.micReservedByModelLab else {
            lastError = "Finish the recording in Models first — it's using the microphone."
            return
        }
        let free = HardwareInfo.freeDiskBytes(maxAge: 0)
        guard free >= Self.minimumFreeBytes else {
            lastError = "Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this Mac. A meeting needs at least 2 GB to be safe."
            return
        }
        var session = MeetingSession(
            id: UUID(),
            title: Self.defaultTitle(for: Date()),
            startedAt: Date(),
            duration: 0,
            audioFile: nil,
            interrupted: true
        )
        let relative = "\(session.id.uuidString)/audio.wav"
        session.audioFile = relative
        let url = directory.appendingPathComponent(relative)
        do {
            recorder.preferredInput = (Settings.shared.inputDeviceUID, Settings.shared.inputDeviceName)
            try await recorder.start(to: url, includeSystemAudio: includeSystemAudio)
        } catch {
            lastError = "The meeting couldn't start: \(error.localizedDescription)"
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
            return
        }
        session.source = recorder.source
        sessions.insert(session, at: 0)
        persist()
        recordingID = session.id
        recordingSource = recorder.source
        elapsed = 0
        state.meetingRecording = true
        AppDelegate.shared?.holdMeetingActivity(true)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let id = self.recordingID, let start = self.session(id: id)?.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Ends the meeting and, when there is a model and the user asked for it,
    /// transcribes straight away.
    func stop(thenTranscribe: Bool = true) async {
        guard let id = recordingID else { return }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        let seconds = await recorder.stop()
        recordingID = nil
        level = 0
        AppState.shared.meetingRecording = false
        AppDelegate.shared?.holdMeetingActivity(false)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].duration = seconds
        sessions[index].interrupted = false
        sessions[index].audioBytes = audioBytes(sessions[index])
        persist()
        if thenTranscribe, seconds > 1 {
            await transcribe(id)
        }
    }

    /// Sessions left `interrupted` by a crash or a quit: the WAV's own header
    /// says how long they really are.
    private func reconcileInterrupted() {
        for index in sessions.indices where sessions[index].interrupted {
            guard let url = audioURL(for: sessions[index]),
                  let bytes = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64,
                  bytes > 44 else {
                sessions[index].audioFile = nil
                continue
            }
            sessions[index].audioBytes = bytes
            sessions[index].duration = Double(bytes - 44) / (MeetingRecorder.sampleRate * 4)
        }
    }

    // MARK: Transcription

    /// Chunked, not one giant decode: 30 s windows with 2 s overlap, each
    /// silence-gated (a meeting is mostly silence from any one channel's point
    /// of view) and timestamped by window position.
    func transcribe(_ id: UUID) async {
        guard transcribingID == nil, let index = sessions.firstIndex(where: { $0.id == id }),
              let url = audioURL(for: sessions[index]) else { return }
        guard let transcriber = AppDelegate.shared?.transcriberRef else { return }
        let state = AppState.shared
        guard state.mode == .idle || state.mode == .done || state.mode == .error else {
            lastError = "Finish the current dictation first — it's using the model."
            return
        }
        lastError = nil
        transcribingID = id
        transcribeProgress = 0
        state.engineReservedByMeeting = true
        defer {
            transcribingID = nil
            state.engineReservedByMeeting = false
        }
        guard await transcriber.ensureLoaded() else {
            lastError = "The model isn't loaded."
            return
        }
        let samples: [Float]
        do {
            // Both channels are folded to mono by the import — the "mixed"
            // transcript v1 wants.
            samples = try await AudioFileImport.loadSamples(from: url)
        } catch {
            lastError = "The recording couldn't be read: \(error.localizedDescription)"
            return
        }
        let result = await MeetingTranscription.run(
            samples: samples, transcriber: transcriber,
            sensitivity: Settings.shared.vadSensitivity,
            trimSilence: Settings.shared.vadTrimSilence,
            biasTerms: DictionaryStore.shared.biasingTerms(),
            onProgress: { [weak self] progress in self?.transcribeProgress = progress }
        )
        guard let index2 = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index2].segments = result.segments
        sessions[index2].modelId = Settings.shared.modelId
        persist()
        if let failure = result.failure {
            lastError = failure
        } else if result.segments.isEmpty {
            lastError = "No speech was found in that recording."
        }
    }

    // MARK: Minutes

    /// Runs the minutes mode (or any of the user's modes) over the transcript
    /// through the ordinary LLM pipeline, so long meetings are map-reduced
    /// exactly like a long dictation.
    func summarize(_ id: UUID, mode: CustomMode = MeetingStore.minutesMode) async {
        guard summarizingID == nil, let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].segments.isEmpty else { return }
        guard let runner = AppDelegate.shared?.llmRunnerRef else { return }
        guard let connection = LLMConnectionStore.shared.active, connection.isUsable else {
            lastError = "Minutes need an AI connection — add one on the AI page. The transcript is already yours."
            return
        }
        lastError = nil
        summarizingID = id
        defer { summarizingID = nil }
        let transcript = sessions[index].timestampedTranscript
        switch await runner.preview(transcript, mode: mode, connection: connection) {
        case .processed(let markdown):
            guard let index2 = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index2].summary = MeetingSummary(
                markdown: markdown,
                generatedBy: "\(connection.name) · \(connection.model)",
                generatedAt: Date()
            )
            persist()
        case .failed(let reason):
            lastError = reason
        }
    }

    // MARK: Editing / removal

    func rename(_ id: UUID, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = trimmed.isEmpty ? Self.defaultTitle(for: sessions[index].startedAt) : trimmed
        persist()
    }

    /// The retention control people actually want: the audio goes, the
    /// transcript and minutes stay.
    func deleteAudio(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), recordingID != id else { return }
        if playingID == id { stopPlayback() }
        if let url = audioURL(for: sessions[index]) {
            try? fileManager.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
        sessions[index].audioFile = nil
        sessions[index].audioBytes = 0
        persist()
    }

    func delete(_ id: UUID) {
        guard recordingID != id, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if playingID == id { stopPlayback() }
        let folder = directory.appendingPathComponent(sessions[index].id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: folder)
        sessions.remove(at: index)
        persist()
    }

    var totalAudioBytes: Int64 { sessions.reduce(0) { $0 + $1.audioBytes } }

    // MARK: Playback

    /// Plays the recording from `seconds` — click a transcript line to hear
    /// what was actually said.
    func play(_ id: UUID, from seconds: TimeInterval) {
        guard let session = session(id: id), let url = audioURL(for: session) else { return }
        if playingID != id || player == nil {
            stopPlayback()
            guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
                lastError = "The recording couldn't be played."
                return
            }
            player = newPlayer
            newPlayer.prepareToPlay()
        }
        guard let player else { return }
        player.currentTime = max(0, min(seconds, max(0, player.duration - 0.1)))
        player.play()
        playingID = id
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case markdown, text, json, audio
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markdown: return "Markdown"
            case .text:     return "Plain text"
            case .json:     return "JSON"
            case .audio:    return "Audio (WAV)"
            }
        }
        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .text:     return "txt"
            case .json:     return "json"
            case .audio:    return "wav"
            }
        }
    }

    func export(_ id: UUID, as format: ExportFormat) {
        guard let session = session(id: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            switch format {
            case .markdown:
                try session.markdownExport.write(to: destination, atomically: true, encoding: .utf8)
            case .text:
                try session.timestampedTranscript.write(to: destination, atomically: true, encoding: .utf8)
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(session).write(to: destination)
            case .audio:
                guard let source = audioURL(for: session) else { return }
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return "Meeting \(formatter.string(from: date))"
    }

    private func audioBytes(_ session: MeetingSession) -> Int64 {
        guard let url = audioURL(for: session) else { return 0 }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? decoder.decode([MeetingSession].self, from: data)) ?? []
    }
}
