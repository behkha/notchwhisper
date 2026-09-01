import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

/// Drives the Upload page: pick (or drop) an audio/video file, decode it,
/// run it through the same engine + dictionary pipeline dictation uses, and
/// hand back editable text.
///
/// A singleton so a finished transcript survives switching sidebar pages (the
/// detail views are rebuilt on every nav change) and so a long run keeps going
/// while the user looks at Transcripts or Models.
@MainActor final class FileTranscribeModel: ObservableObject {
    static let shared = FileTranscribeModel()

    enum Phase: Equatable {
        case empty          // nothing picked yet
        case reading        // decoding the file to 16 kHz mono
        case ready          // decoded, waiting for the user to hit Transcribe
        case transcribing
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var fileURL: URL?
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var rawText: String = ""
    @Published private(set) var corrections: [CorrectionChange] = []
    /// The result, editable in place before copying or saving.
    @Published var text: String = ""

    private var samples: [Float] = []
    private var work: Task<Void, Never>?
    private var cancelFlag = CancelFlag()

    var fileName: String { fileURL?.lastPathComponent ?? "" }
    var isBusy: Bool { phase == .reading || phase == .transcribing }
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    // MARK: Picking

    /// Open panel, filtered to what the decoders actually handle.
    func pick() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an audio or video file"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = AudioFileImport.allowedContentTypes
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    /// Accept a file from the open panel or from a drop.
    func select(_ url: URL) {
        guard !isBusy else { return }
        work?.cancel()
        reset()
        fileURL = url
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        phase = .reading
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.work = nil }
            do {
                let decoded = try await AudioFileImport.loadSamples(from: url)
                guard !Task.isCancelled else { return }
                guard !decoded.isEmpty else { throw AudioFileImport.ImportError.empty }
                self.samples = decoded
                self.duration = Double(decoded.count) / AudioFileImport.sampleRate
                self.phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.samples = []
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Transcribing

    func transcribe() {
        // `.failed` is retryable too — a failed run (model busy, engine error)
        // keeps the decoded samples, so the button must work without a re-pick.
        guard !isBusy, !samples.isEmpty, work == nil else { return }
        guard let delegate = AppDelegate.shared else {
            phase = .failed("The transcription engine isn't available.")
            return
        }
        // One engine, one caller at a time: a decode running while the mic
        // pipeline holds the model would interleave two transcriptions on the
        // same WhisperKit/llama context.
        let state = AppState.shared
        if state.mode == .recording || state.mode == .dictating
            || state.mode == .transcribing || state.mode == .improving {
            phase = .failed("Finish the current dictation first — it's using the model.")
            return
        }

        let flag = CancelFlag()
        cancelFlag = flag
        progress = 0
        text = ""
        rawText = ""
        corrections = []
        phase = .transcribing

        let transcriber = delegate.transcriberRef
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.work = nil }

            guard await transcriber.ensureLoaded() else {
                if !flag.isCancelled { self.phase = .failed("The model isn't loaded.") }
                return
            }
            let bias = DictionaryStore.shared.biasingTerms()
            let clip = self.samples
            do {
                let raw = try await transcriber.transcribeFile(
                    clip,
                    biasTerms: bias,
                    isCancelled: { flag.isCancelled },
                    onProgress: { p in
                        Task { @MainActor [weak self] in
                            guard let self, self.phase == .transcribing else { return }
                            if p > self.progress { self.progress = p }
                        }
                    }
                )
                guard !flag.isCancelled else { self.phase = .ready; self.progress = 0; return }

                // Same guaranteed correction pass dictation runs.
                let (final, changes) = DictionaryStore.shared.applyCorrections(raw)
                self.rawText = raw
                self.corrections = changes
                self.text = final
                self.progress = 1
                self.phase = final.isEmpty
                    ? .failed("The model found no speech in that file.")
                    : .done
                if !final.isEmpty {
                    HistoryStore.shared.add(
                        raw: raw, final: final, corrections: changes, source: .file
                    )
                }
            } catch is CancellationError {
                self.phase = .ready
                self.progress = 0
            } catch {
                guard !flag.isCancelled else { self.phase = .ready; self.progress = 0; return }
                self.phase = .failed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
        work?.cancel()
        work = nil
        if phase == .transcribing { phase = .ready }
        if phase == .reading { reset() }
        progress = 0
    }

    /// Clear everything back to the drop zone.
    func reset() {
        cancelFlag.cancel()
        work?.cancel()
        work = nil
        samples = []
        fileURL = nil
        fileSize = 0
        duration = 0
        progress = 0
        text = ""
        rawText = ""
        corrections = []
        phase = .empty
    }

    // MARK: Output

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Save the transcript next to wherever the user chooses, defaulting to the
    /// source file's name with a `.txt` extension.
    func saveAsText() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue =
            (fileURL?.deletingPathExtension().lastPathComponent ?? "Transcript") + ".txt"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}

/// Thread-safe cancel latch. The engine callbacks that poll it run off the
/// MainActor (WhisperKit's decode loop, the llama.cpp queue), so a plain Bool
/// would be a data race.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

// MARK: - View

/// The Upload page: drop or choose a recording, transcribe it on-device, read
/// and edit the text.
struct FileTranscribeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var model = FileTranscribeModel.shared

    @State private var dropTargeted = false
    @State private var copied = false

    var body: some View {
        let _ = theme.theme
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                SectionHeader("Transcribe a file",
                              eyebrow: "Upload",
                              subtitle: "Drop in a recording — it's transcribed on this Mac, and nothing is uploaded anywhere.") {
                    Chip(text: ModelRegistry.shared.descriptor(for: settings.modelId).displayName,
                         systemImage: "cpu", tint: Tokens.Color.accent)
                }

                if model.fileURL == nil {
                    dropZone
                } else {
                    fileCard
                }

                if let error = model.errorMessage { errorBanner(error) }

                if !model.text.isEmpty { resultCard }
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: Tokens.Space.x3) {
            IconTile("arrow.up.doc.fill", size: 56)
            Text("Drop an audio or video file")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
            Text("MP3, WAV, M4A, AAC, FLAC, AIFF, CAF, MP4, MOV — any length.")
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Choose file…") { model.pick() }
                .primaryAction()
                .padding(.top, Tokens.Space.x1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .card(padding: nil)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(
                    Tokens.Color.accent.opacity(dropTargeted ? 0.9 : 0.28),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [7, 6])
                )
                .padding(6)
        )
        .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: dropTargeted)
    }

    // MARK: Picked file

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            HStack(alignment: .top, spacing: Tokens.Space.x3) {
                IconTile("waveform", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.fileName)
                        .font(Tokens.TypeScale.title2)
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(metaLine)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer(minLength: Tokens.Space.x3)
                actions
            }

            switch model.phase {
            case .reading:
                progressLine(label: "Reading audio…", value: nil)
            case .transcribing:
                progressLine(
                    label: model.progress > 0.001
                        ? "Transcribing… \(Int((model.progress * 100).rounded()))%"
                        : "Transcribing…",
                    value: max(model.progress, 0.02)
                )
            default:
                EmptyView()
            }
        }
        .card()
    }

    private var metaLine: String {
        var parts: [String] = []
        if model.duration > 0 { parts.append(AudioFileImport.durationLabel(seconds: model.duration)) }
        if model.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file))
        }
        parts.append(model.fileURL?.pathExtension.uppercased() ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Tokens.Space.x2) {
            switch model.phase {
            case .reading, .transcribing:
                Button("Cancel") { model.cancel() }.secondaryAction()
            default:
                Button { model.reset() } label: { Label("Remove", systemImage: "xmark") }
                    .secondaryAction()
                Button(model.phase == .done ? "Transcribe again" : "Transcribe") {
                    model.transcribe()
                }
                .primaryAction()
                .disabled(model.duration <= 0)
            }
        }
    }

    private func progressLine(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                if let value, model.duration > 0 {
                    Text("\(AudioFileImport.durationLabel(seconds: value * model.duration)) / \(AudioFileImport.durationLabel(seconds: model.duration))")
                        .font(Tokens.TypeScale.caption).monospacedDigit()
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
            if let value {
                ProgressView(value: value).tint(Tokens.Color.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Tokens.Color.accent)
            }
        }
    }

    // MARK: Result

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(spacing: Tokens.Space.x2) {
                Text("TRANSCRIPT")
                    .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                    .foregroundStyle(Tokens.Color.textTert)
                Chip(text: "\(model.wordCount) words", tint: Tokens.Color.textSec, filled: false)
                if !model.corrections.isEmpty {
                    Chip(text: "\(model.corrections.count) dictionary fix\(model.corrections.count == 1 ? "" : "es")",
                         systemImage: "wand.and.sparkles", tint: Tokens.Color.accent)
                }
                Spacer()
                Button {
                    model.copyToClipboard()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .symbolFeedback(value: copied)
                }
                .secondaryAction()
                Button { model.saveAsText() } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .secondaryAction()
            }

            TextEditor(text: $model.text)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .frame(minHeight: 260)
                .padding(Tokens.Space.x2)
                .background(Tokens.Color.fillQuieter,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Color.hairline, lineWidth: 1)
                )

            Text("Saved to Transcripts. Edit here before copying — changes stay on this page.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
        }
        .card()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Color.warn)
            Text(message)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.warn.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.Color.warn.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in FileTranscribeModel.shared.select(url) }
        }
        return true
    }
}
