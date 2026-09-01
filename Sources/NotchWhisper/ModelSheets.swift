import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared sheet chrome

/// Common frame, header and close behaviour for every Models sheet, so they
/// read as one product rather than seven dialogs.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var minWidth: CGFloat = 620
    var minHeight: CGFloat = 460
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Tokens.Space.x3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Tokens.TypeScale.title1)
                        .foregroundStyle(Tokens.Color.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                .accessibilityLabel("Close")
            }
            .padding(Tokens.Space.x5)

            Divider().overlay(Tokens.Color.hairline)

            ScrollView {
                content()
                    .padding(Tokens.Space.x5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: minWidth, idealWidth: minWidth + 60, maxWidth: 900,
               minHeight: minHeight, idealHeight: minHeight + 120, maxHeight: 860)
        .background(Tokens.Color.bg)
        .environment(\.colorScheme, .dark)
        .onKeyPress(.escape) { onClose(); return .handled }
    }
}

// MARK: - Audio capture panel
//
// Shared by the test playground and the benchmark sample recorder: record from
// the mic, or drop / choose an audio file. Nothing leaves the Mac.

struct AudioCapturePanel: View {
    var prompt: String = "Record a few seconds of speech, or drop an audio file."
    let onCaptured: ([Float], String) -> Void

    @EnvironmentObject private var state: AppState
    @State private var isRecording = false
    @State private var isDecoding = false
    @State private var elapsed: TimeInterval = 0
    @State private var dropTargeted = false
    @State private var error: String?
    @State private var ticker: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text(prompt)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Tokens.Space.x3) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isRecording
                             ? "Stop (\(String(format: "%.1f", elapsed))s)"
                             : "Record")
                            .font(Tokens.TypeScale.captionSB)
                            .monospacedDigit()
                    }
                    .foregroundStyle(isRecording ? Tokens.Color.record : Tokens.Color.onAccent)
                    .padding(.horizontal, Tokens.Space.x4)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(isRecording
                                               ? AnyShapeStyle(Tokens.Color.record.opacity(0.16))
                                               : AnyShapeStyle(Tokens.Color.accentGradient)))
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .disabled(isDecoding || (!isRecording && state.mode != .idle))

                Button("Choose audio file…") { chooseFile() }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                    .disabled(isRecording || isDecoding)

                if isDecoding {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Decoding…").font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                Spacer(minLength: 0)
            }

            if isRecording {
                LevelsMeter(height: 40)
            }

            if state.mode != .idle && !isRecording {
                Text("Recording is unavailable while a dictation is in progress.")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.warn)
            }

            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(dropTargeted ? Tokens.Color.accent : Tokens.Color.hairline)
                .frame(height: 60)
                .overlay(
                    Text(dropTargeted ? "Drop to use this audio" : "or drop an audio file here")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(dropTargeted ? Tokens.Color.accent : Tokens.Color.textTert)
                )
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Closing the sheet mid-recording must always release the microphone.
        .onDisappear {
            if isRecording { _ = AppDelegate.shared?.recorderRef.stop() }
            state.micReservedByModelLab = false
            ticker?.cancel()
        }
    }

    private func startRecording() {
        guard let recorder = AppDelegate.shared?.recorderRef else { return }
        error = nil
        do {
            try recorder.start()
            // Claim the shared microphone so a hotkey press can't start a
            // second capture session on top of this one.
            state.micReservedByModelLab = true
            isRecording = true
            elapsed = 0
            ticker = Task {
                while !Task.isCancelled && isRecording {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    elapsed += 0.1
                }
            }
        } catch {
            self.error = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard let recorder = AppDelegate.shared?.recorderRef else { return }
        isRecording = false
        ticker?.cancel()
        let samples = recorder.stop()
        state.micReservedByModelLab = false
        guard !samples.isEmpty else {
            error = "Nothing was recorded."
            return
        }
        onCaptured(samples, "Recording")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioFileImport.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        decode(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, AudioFileImport.looksSupported(url) else { return }
            Task { @MainActor in decode(url) }
        }
        return true
    }

    private func decode(_ url: URL) {
        isDecoding = true
        error = nil
        Task {
            defer { isDecoding = false }
            do {
                let samples = try await AudioFileImport.loadSamples(from: url)
                onCaptured(samples, url.lastPathComponent)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Test playground (§22)

/// Try a model without leaving the Models page: record or import audio, run it
/// through the chosen engine, read the transcript and the latency.
struct ModelTestSheet: View {
    let modelId: String
    let onClose: () -> Void

    @EnvironmentObject private var state: AppState
    @ObservedObject private var registry = ModelRegistry.shared

    @State private var selectedId: String
    @State private var samples: [Float] = []
    @State private var sourceName = ""
    @State private var transcript = ""
    @State private var processingSeconds: Double?
    @State private var isRunning = false
    @State private var error: String?

    init(modelId: String, onClose: @escaping () -> Void) {
        self.modelId = modelId
        self.onClose = onClose
        _selectedId = State(initialValue: modelId)
    }

    private var model: ModelDescriptor { registry.descriptor(for: selectedId) }

    var body: some View {
        SheetScaffold(
            title: "Test \(model.displayName)",
            subtitle: "Audio and transcripts stay on your Mac.",
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                if registry.installedIds.count > 1 {
                    HStack(spacing: Tokens.Space.x2) {
                        Text("Model").font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                        Picker("", selection: $selectedId) {
                            ForEach(registry.installedDescriptors) { Text($0.displayName).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .disabled(isRunning)
                        Spacer(minLength: 0)
                    }
                }

                AudioCapturePanel(prompt: "Record yourself, or drop an audio file, then transcribe it with this model.") { captured, name in
                    samples = captured
                    sourceName = name
                    transcript = ""
                    processingSeconds = nil
                }

                if !samples.isEmpty {
                    HStack(spacing: Tokens.Space.x3) {
                        Label("\(sourceName) · \(AudioFileImport.durationLabel(samples: samples.count))",
                              systemImage: "waveform")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                        Spacer(minLength: 0)
                        Button {
                            run()
                        } label: {
                            HStack(spacing: 6) {
                                if isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                                Text(isRunning ? "Transcribing…" : "Transcribe")
                                    .font(Tokens.TypeScale.captionSB)
                            }
                            .foregroundStyle(Tokens.Color.onAccent)
                            .padding(.horizontal, Tokens.Space.x4)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Tokens.Color.accentGradient))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(Pressable(scale: 0.97))
                        .disabled(isRunning)
                    }
                }

                if let error {
                    InlineBanner(kind: .error, title: "Couldn't transcribe", message: error)
                }

                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                        HStack {
                            Text("Transcript")
                                .font(Tokens.TypeScale.headline)
                                .foregroundStyle(Tokens.Color.text)
                            Spacer(minLength: 0)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(transcript, forType: .string)
                            }
                            .buttonStyle(.plain)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.accent)
                        }
                        Text(transcript)
                            .font(Tokens.TypeScale.body)
                            .foregroundStyle(Tokens.Color.textSec)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.x4)
                            .card(padding: nil, elevated: false)
                        if let seconds = processingSeconds {
                            let rtf = seconds / max(0.001, Double(samples.count) / AudioFileImport.sampleRate)
                            Text(String(format: "Processing time: %.2f s · %.2f× real time", seconds, rtf))
                                .font(Tokens.TypeScale.caption)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                    }
                }
            }
        }
    }

    private func run() {
        guard let transcriber = AppDelegate.shared?.transcriberRef else { return }
        isRunning = true
        error = nil
        transcript = ""
        let previous = Settings.shared.modelId
        Task {
            defer { isRunning = false }
            guard await transcriber.ensureLoaded(modelId: selectedId) else {
                error = state.statusMessage.nilIfEmpty ?? "The model couldn't be loaded."
                if previous != selectedId { _ = await transcriber.ensureLoaded(modelId: previous) }
                return
            }
            let start = Date()
            do {
                transcript = try await transcriber.transcribeFile(samples)
                processingSeconds = Date().timeIntervalSince(start)
                if transcript.isEmpty { transcript = "(no speech detected)" }
            } catch {
                self.error = error.localizedDescription
            }
            // Testing must never leave the user on a different engine.
            if previous != selectedId { _ = await transcriber.ensureLoaded(modelId: previous) }
        }
    }
}

// MARK: - Benchmark (§20)

struct ModelBenchmarkSheet: View {
    let modelId: String
    let onClose: () -> Void

    @ObservedObject private var service = ModelBenchmarkService.shared
    @ObservedObject private var registry = ModelRegistry.shared

    @State private var reference = ""
    @State private var error: String?
    @State private var showSampleCapture = false

    private var model: ModelDescriptor { registry.descriptor(for: modelId) }

    var body: some View {
        SheetScaffold(
            title: "Benchmark",
            subtitle: "Every model is timed on the same audio, on this Mac. Results stay local.",
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                sampleSection
                if service.hasSample { runSection }
                if !service.leaderboard.isEmpty { leaderboardSection }
            }
        }
        .onAppear { reference = service.sample?.referenceTranscript ?? "" }
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("Benchmark audio")
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.text)

            if let sample = service.sample, !showSampleCapture {
                HStack(spacing: Tokens.Space.x3) {
                    IconTile("waveform", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sample.sourceName) · \(sample.durationLabel)")
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.text)
                        Text("Captured \(ModelsView.relative(sample.createdAt))")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    Spacer(minLength: 0)
                    Button("Replace") { showSampleCapture = true }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                    Button("Delete recording") { service.deleteSample() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.danger)
                }
                .padding(Tokens.Space.x4)
                .card(padding: nil, elevated: false)

                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    Text("Reference transcript (optional)")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                    TextField("Type exactly what the audio says to get a word error rate.",
                              text: $reference, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .font(Tokens.TypeScale.caption)
                        .onSubmit { service.setReferenceTranscript(reference) }
                    Button("Save reference") { service.setReferenceTranscript(reference) }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.accent)
                }
            } else {
                AudioCapturePanel(prompt: "Record a short sample once — every model is then timed on exactly that audio, so the numbers are comparable.") { samples, name in
                    do {
                        try service.setSample(samples, sourceName: name)
                        showSampleCapture = false
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }

            if let error {
                InlineBanner(kind: .warning, title: "Benchmark", message: error)
            }
            Text("Benchmark recordings are stored on this Mac and are never uploaded.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Divider().overlay(Tokens.Color.hairline)
            HStack(spacing: Tokens.Space.x3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)
                    Text(service.result(for: modelId).map { "Last run \(ModelsView.relative($0.ranAt))" }
                         ?? "Not benchmarked on this Mac")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer(minLength: 0)
                Button { runBenchmark() } label: {
                    HStack(spacing: 6) {
                        if service.runningModelId == modelId {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        }
                        Text(service.isRunning ? (service.phase.isEmpty ? "Running…" : service.phase)
                             : "Run benchmark")
                            .font(Tokens.TypeScale.captionSB)
                    }
                    .foregroundStyle(Tokens.Color.onAccent)
                    .padding(.horizontal, Tokens.Space.x4)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Tokens.Color.accentGradient))
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .disabled(service.isRunning || !registry.installedIds.contains(modelId))
            }

            if let result = service.result(for: modelId) {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    HStack(alignment: .top, spacing: Tokens.Space.x4) {
                        MetricCell(label: "Audio duration",
                                   value: String(format: "%.1f s", result.audioSeconds))
                        MetricCell(label: "Processing time", value: result.processLabel)
                        MetricCell(label: "Real-time factor", value: result.rtfLabel)
                        MetricCell(label: "Peak memory", value: result.memoryLabel)
                    }
                    HStack(alignment: .top, spacing: Tokens.Space.x4) {
                        MetricCell(label: "Load time", value: result.loadLabel)
                        MetricCell(label: "First result",
                                   value: result.firstResultSeconds.map { String(format: "%.2f s", $0) } ?? "—",
                                   isUnknown: result.firstResultSeconds == nil)
                        MetricCell(label: "CPU (all cores)", value: result.cpuLabel)
                        MetricCell(label: "Word error rate", value: result.werLabel ?? "—",
                                   note: result.werLabel == nil ? "Add a reference transcript" : nil,
                                   isUnknown: result.werLabel == nil)
                    }
                    if !result.verdict.isEmpty {
                        Label(result.verdict, systemImage: "checkmark.seal.fill")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.success)
                    }
                    DisclosureSection("Transcript produced") {
                        Text(result.transcript.isEmpty ? "(no speech detected)" : result.transcript)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Tokens.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: nil, elevated: false)
            }

            if let lastError = service.lastError {
                InlineBanner(kind: .error, title: "Benchmark failed", message: lastError)
            }
        }
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Divider().overlay(Tokens.Color.hairline)
            Text("Your Mac")
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.text)
            VStack(spacing: 0) {
                ForEach(service.leaderboard) { result in
                    HStack(spacing: Tokens.Space.x3) {
                        Text(result.modelName)
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(result.modelId == modelId
                                             ? Tokens.Color.text : Tokens.Color.textSec)
                        Spacer(minLength: Tokens.Space.x3)
                        Text(result.rtfLabel)
                            .font(Tokens.TypeScale.caption).monospacedDigit()
                            .foregroundStyle(Tokens.Color.textTert)
                        Text(result.processLabel)
                            .font(Tokens.TypeScale.captionSB).monospacedDigit()
                            .foregroundStyle(Tokens.Color.text)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                }
            }
            Text("Timed on the same \(service.sample?.durationLabel ?? "") sample. Lower is faster.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
        }
    }

    private func runBenchmark() {
        Task {
            do { _ = try await service.run(modelId: modelId) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Compare (§21)

struct ModelCompareSheet: View {
    let initialIds: [String]
    let onClose: () -> Void

    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var service = ModelBenchmarkService.shared

    @State private var leftId: String
    @State private var rightId: String
    @State private var isRunning = false

    init(initialIds: [String], onClose: @escaping () -> Void) {
        self.initialIds = initialIds
        self.onClose = onClose
        _leftId = State(initialValue: initialIds.first ?? "")
        _rightId = State(initialValue: initialIds.count > 1 ? initialIds[1] : (initialIds.first ?? ""))
    }

    private var left: ModelDescriptor { registry.descriptor(for: leftId) }
    private var right: ModelDescriptor { registry.descriptor(for: rightId) }

    var body: some View {
        SheetScaffold(
            title: "Compare models",
            subtitle: "Published figures where they exist, and your own measurements where you've run them.",
            minWidth: 700,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                HStack(spacing: Tokens.Space.x4) {
                    picker("First", $leftId)
                    picker("Second", $rightId)
                }

                VStack(spacing: 0) {
                    compareHeader
                    Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                    compareRow("Speed", value(left.speed), value(right.speed))
                    compareRow("Accuracy", value(left.accuracy), value(right.accuracy))
                    compareRow("Languages", left.capabilities.languageCountLabel,
                               right.capabilities.languageCountLabel)
                    compareRow("Memory", left.resources.memoryLabel, right.resources.memoryLabel)
                    compareRow("Disk", left.resources.diskLabel, right.resources.diskLabel)
                    compareRow("Runtime", left.engine.displayName, right.engine.displayName)
                    compareRow("Live dictation",
                               left.capabilities.streaming ? "Yes" : "No",
                               right.capabilities.streaming ? "Yes" : "No")
                    Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                    compareRow("Your benchmark",
                               service.result(for: leftId)?.processLabel ?? "Not benchmarked",
                               service.result(for: rightId)?.processLabel ?? "Not benchmarked",
                               emphasised: true)
                    compareRow("Real-time factor",
                               service.result(for: leftId)?.rtfLabel ?? "—",
                               service.result(for: rightId)?.rtfLabel ?? "—")
                    compareRow("Peak memory",
                               service.result(for: leftId)?.memoryLabel ?? "—",
                               service.result(for: rightId)?.memoryLabel ?? "—")
                }
                .padding(Tokens.Space.x4)
                .card(padding: nil, elevated: false)

                if let verdict = comparativeVerdict {
                    InlineBanner(kind: .success, title: "Benchmark complete", message: verdict)
                }

                HStack(spacing: Tokens.Space.x3) {
                    Button {
                        runBoth()
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                            Text(isRunning ? (service.phase.isEmpty ? "Running…" : service.phase)
                                 : "Run both on the same audio")
                                .font(Tokens.TypeScale.captionSB)
                        }
                        .foregroundStyle(Tokens.Color.onAccent)
                        .padding(.horizontal, Tokens.Space.x4)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Tokens.Color.accentGradient))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(Pressable(scale: 0.97))
                    .disabled(isRunning || leftId == rightId || !service.hasSample)

                    if !service.hasSample {
                        Text("Record a benchmark sample first (Benchmark → Record).")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                    Spacer(minLength: 0)
                    Button("Use \(left.displayName)") { registry.activate(leftId); onClose() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                        .disabled(leftId == registry.activeId)
                    Button("Use \(right.displayName)") { registry.activate(rightId); onClose() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                        .disabled(rightId == registry.activeId)
                }

                if let l = service.result(for: leftId), let r = service.result(for: rightId) {
                    transcriptComparison(l, r)
                }
            }
        }
    }

    private func picker(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            Picker("", selection: binding) {
                ForEach(registry.installedDescriptors) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden()
            .disabled(isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compareHeader: some View {
        HStack(spacing: Tokens.Space.x3) {
            Text("").frame(width: 130, alignment: .leading)
            Text(left.displayName)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            Text(right.displayName)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.bottom, Tokens.Space.x2)
    }

    private func compareRow(_ label: String, _ a: String, _ b: String,
                            emphasised: Bool = false) -> some View {
        HStack(spacing: Tokens.Space.x3) {
            Text(label)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .frame(width: 130, alignment: .leading)
            Text(a)
                .font(emphasised ? Tokens.TypeScale.captionSB : Tokens.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(emphasised ? Tokens.Color.text : Tokens.Color.textSec)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(b)
                .font(emphasised ? Tokens.TypeScale.captionSB : Tokens.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(emphasised ? Tokens.Color.text : Tokens.Color.textSec)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label). \(left.displayName): \(a). \(right.displayName): \(b).")
    }

    private func value(_ metric: RatedMetric) -> String {
        metric.isKnown ? metric.display : "Not benchmarked"
    }

    /// Only ever states a comparison that both measurements support.
    private var comparativeVerdict: String? {
        guard leftId != rightId,
              let l = service.result(for: leftId), let r = service.result(for: rightId),
              l.processSeconds > 0, r.processSeconds > 0 else { return nil }
        let (faster, slower) = l.processSeconds < r.processSeconds ? (l, r) : (r, l)
        let percent = Int(((slower.processSeconds - faster.processSeconds) / slower.processSeconds * 100).rounded())
        guard percent >= 1 else {
            return "\(l.modelName) and \(r.modelName) finished this audio in the same time on your Mac."
        }
        return "\(faster.modelName) is \(percent)% faster than \(slower.modelName) on this Mac."
    }

    @ViewBuilder
    private func transcriptComparison(_ l: BenchmarkResult, _ r: BenchmarkResult) -> some View {
        DisclosureSection("Transcripts side by side") {
            HStack(alignment: .top, spacing: Tokens.Space.x4) {
                transcriptColumn(l)
                transcriptColumn(r)
            }
        }
    }

    private func transcriptColumn(_ result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.modelName)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.text)
            Text(result.transcript.isEmpty ? "(no speech detected)" : result.transcript)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.x3)
        .background(Tokens.Color.fillQuieter,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    private func runBoth() {
        isRunning = true
        Task {
            defer { isRunning = false }
            _ = await service.runComparison(modelIds: [leftId, rightId])
        }
    }
}

// MARK: - Import (§33)

struct ModelImportSheet: View {
    let onClose: () -> Void

    @ObservedObject private var importer = ModelImporter.shared
    @State private var name = ""
    @State private var copyIntoStorage = true

    var body: some View {
        SheetScaffold(
            title: "Import model",
            subtitle: "Add a Core ML Whisper folder or a GGUF speech model from your disk.",
            minHeight: 380,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                if let candidate = importer.candidate {
                    VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                        Label("Model detected", systemImage: "checkmark.seal.fill")
                            .font(Tokens.TypeScale.headline)
                            .foregroundStyle(Tokens.Color.success)

                        HStack(alignment: .top, spacing: Tokens.Space.x4) {
                            MetricCell(label: "Format", value: candidate.format.displayName)
                            MetricCell(label: "Runtime", value: candidate.engine.detailName)
                            MetricCell(label: "Size", value: candidate.sizeLabel)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(candidate.notes, id: \.self) { note in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Tokens.Color.success)
                                    Text(note)
                                        .font(Tokens.TypeScale.caption)
                                        .foregroundStyle(Tokens.Color.textSec)
                                }
                            }
                        }

                        SpecLine(label: "Source", value: candidate.sourceURL.path, monospaced: true)

                        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                            Text("Name").font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textTert)
                            TextField(candidate.suggestedName, text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }

                        Picker("", selection: $copyIntoStorage) {
                            Text("Copy into managed storage").tag(true)
                            Text("Use the files where they are").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Text(copyIntoStorage
                             ? "A copy is kept with your other models, so moving or deleting the original is safe."
                             : "No duplicate is made. If these files move or are deleted, the model stops working.")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: Tokens.Space.x3) {
                            Button("Cancel") { importer.candidate = nil; onClose() }
                                .secondaryAction()
                            Button {
                                Task {
                                    await importer.commit(candidate, name: name,
                                                          copyIntoManagedStorage: copyIntoStorage)
                                    if importer.error == nil { onClose() }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if importer.isImporting {
                                        ProgressView().controlSize(.small).scaleEffect(0.7)
                                    }
                                    Text(importer.isImporting ? "Adding…" : "Add to Models")
                                }
                            }
                            .primaryAction()
                            .disabled(importer.isImporting)
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                        Text("Drop a supported model onto the Models page, or choose one here.")
                            .font(Tokens.TypeScale.callout)
                            .foregroundStyle(Tokens.Color.textSec)
                        Text("Accepted: a Core ML Whisper folder containing AudioEncoder.mlmodelc, TextDecoder.mlmodelc and MelSpectrogram.mlmodelc, or a GGUF speech model with its matching mmproj file.")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Choose…") { importer.presentOpenPanel() }
                            .primaryAction()
                    }
                }

                if let error = importer.error {
                    InlineBanner(kind: .error, title: "Couldn't import that model", message: error)
                }
            }
        }
        .onAppear { name = importer.candidate?.suggestedName ?? "" }
    }
}

// MARK: - Storage (§23, §24)

struct ModelStorageSheet: View {
    let report: ModelStorageReport
    let onRefresh: () -> Void
    let onClose: () -> Void

    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var location = ModelStorageLocation.shared
    @EnvironmentObject private var state: AppState

    @State private var confirmUnused = false
    @State private var error: String?

    /// Read live rather than from the report: the sheet can stay open across a
    /// model switch, and a stale "Active" flag would both mislabel the row and
    /// leave its Remove button disabled.
    private func isActive(_ item: ModelStorageReport.Item) -> Bool {
        item.id == registry.activeId
    }

    var body: some View {
        SheetScaffold(
            title: "Model storage",
            subtitle: location.root.path,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                StorageBar(report: report)

                VStack(spacing: 0) {
                    ForEach(report.items) { item in
                        HStack(spacing: Tokens.Space.x3) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Tokens.Space.x2) {
                                    Text(item.name)
                                        .font(Tokens.TypeScale.caption)
                                        .foregroundStyle(Tokens.Color.text)
                                    if isActive(item) {
                                        Text("Active").font(Tokens.TypeScale.micro)
                                            .foregroundStyle(Tokens.Color.success)
                                    }
                                }
                                Text(item.lastUsed.map { "Last used \(ModelsView.relative($0))" }
                                     ?? "Never used")
                                    .font(Tokens.TypeScale.micro)
                                    .foregroundStyle(Tokens.Color.textTert)
                            }
                            Spacer(minLength: Tokens.Space.x3)
                            Text(ModelStorageReport.label(item.bytes))
                                .font(Tokens.TypeScale.caption).monospacedDigit()
                                .foregroundStyle(Tokens.Color.textSec)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.path])
                            } label: {
                                Image(systemName: "folder").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.Color.textTert)
                            .accessibilityLabel("Reveal \(item.name) in Finder")
                            Button {
                                remove(item.id)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isActive(item) ? Tokens.Color.textTert.opacity(0.4)
                                             : Tokens.Color.danger)
                            .disabled(isActive(item))
                            .help(isActive(item)
                                  ? "Choose another model before removing this one."
                                  : "Remove \(item.name)")
                        }
                        .padding(.vertical, Tokens.Space.x2)
                        if item.id != report.items.last?.id {
                            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(Tokens.Space.x4)
                .card(padding: nil, elevated: false)

                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    Text("Manage")
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)

                    if !report.unusedItems.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remove unused models")
                                    .font(Tokens.TypeScale.caption)
                                    .foregroundStyle(Tokens.Color.textSec)
                                Text("\(report.unusedItems.count) model\(report.unusedItems.count == 1 ? "" : "s") unused for 30 days · \(ModelStorageReport.label(report.unusedItems.reduce(0) { $0 + $1.bytes }))")
                                    .font(Tokens.TypeScale.micro)
                                    .foregroundStyle(Tokens.Color.textTert)
                            }
                            Spacer(minLength: 0)
                            Button("Review…") { confirmUnused = true }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.danger)
                        }
                    }

                    if report.incompleteBytes > 0 {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clear interrupted downloads")
                                    .font(Tokens.TypeScale.caption)
                                    .foregroundStyle(Tokens.Color.textSec)
                                Text("\(ModelStorageReport.label(report.incompleteBytes)) of partial files. Clearing them means affected downloads start over.")
                                    .font(Tokens.TypeScale.micro)
                                    .foregroundStyle(Tokens.Color.textTert)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Clear") {
                                Task {
                                    let freed = await registry.clearIncompleteDownloads()
                                    onRefresh()
                                    state.showToast("Freed \(ModelStorageReport.label(freed)).")
                                }
                            }
                            .buttonStyle(.plain)
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.accent)
                        }
                    }

                    Divider().overlay(Tokens.Color.hairline)

                    VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                        Text("Location")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textSec)
                        Text(location.root.path)
                            .font(Tokens.TypeScale.bodyMono)
                            .foregroundStyle(Tokens.Color.textTert)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Tokens.Space.x3) {
                            Button("Change location…") { changeLocation() }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.accent)
                                .disabled(location.isMigrating)
                            if !location.isDefaultLocation {
                                Button("Reset to default") {
                                    Task {
                                        do { try await location.resetToDefault(); onRefresh() }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.textSec)
                            }
                            Button("Reveal in Finder") { location.revealInFinder() }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.textSec)
                            Spacer(minLength: 0)
                        }
                        if location.isMigrating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(location.migrationPhase)
                                    .font(Tokens.TypeScale.caption)
                                    .foregroundStyle(Tokens.Color.textSec)
                            }
                        }
                        Text("Models are copied and verified before anything is deleted, so an interrupted move never loses them.")
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error {
                    InlineBanner(kind: .error, title: "Storage", message: error,
                                 actionTitle: "Dismiss", action: { self.error = nil })
                }
            }
        }
        .task { onRefresh() }
        .confirmationDialog("Remove \(report.unusedItems.count) unused model\(report.unusedItems.count == 1 ? "" : "s")?",
                            isPresented: $confirmUnused, titleVisibility: .visible) {
            Button("Remove \(ModelStorageReport.label(report.unusedItems.reduce(0) { $0 + $1.bytes }))",
                   role: .destructive) { removeUnused() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(report.unusedItems.map(\.name).joined(separator: "\n")
                 + "\n\nBenchmark history is kept.")
        }
    }

    private func remove(_ id: String) {
        Task {
            let freed = await registry.remove(id)
            onRefresh()
            if freed > 0 { state.showToast("Freed \(ModelStorageReport.label(freed)).") }
        }
    }

    private func removeUnused() {
        let ids = report.unusedItems.map(\.id).filter { $0 != registry.activeId }
        Task {
            var freed: Int64 = 0
            for id in ids { freed += await registry.remove(id) }
            onRefresh()
            state.showToast("Removed \(ids.count) model\(ids.count == 1 ? "" : "s") — \(ModelStorageReport.label(freed)) freed.")
        }
    }

    private func changeLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for your models"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await location.migrate(to: url)
                await registry.scan()
                onRefresh()
                state.showToast("Models moved to \(location.root.path).")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Download centre (§60, §61)

struct DownloadCenterSheet: View {
    let onClose: () -> Void

    @ObservedObject private var queue = ModelDownloadQueue.shared

    var body: some View {
        SheetScaffold(
            title: "Downloads",
            subtitle: queue.activeCount == 0
                ? "Nothing is downloading."
                : "\(queue.activeCount) in the queue · one downloads at a time so the speed and time estimates stay accurate.",
            minHeight: 340,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                if queue.jobs.isEmpty {
                    Text("Model downloads appear here, and keep running while you use the rest of the app.")
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                } else {
                    ForEach(queue.jobs) { job in
                        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                            HStack(spacing: Tokens.Space.x2) {
                                Text(job.displayName)
                                    .font(Tokens.TypeScale.captionSB)
                                    .foregroundStyle(Tokens.Color.text)
                                Spacer(minLength: 0)
                                if job.state == .queued {
                                    Button {
                                        queue.move(job.id, up: true)
                                    } label: { Image(systemName: "arrow.up").font(.system(size: 10)) }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Tokens.Color.textTert)
                                        .accessibilityLabel("Move \(job.displayName) earlier")
                                    Button {
                                        queue.move(job.id, up: false)
                                    } label: { Image(systemName: "arrow.down").font(.system(size: 10)) }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Tokens.Color.textTert)
                                        .accessibilityLabel("Move \(job.displayName) later")
                                }
                            }
                            DownloadProgressPanel(
                                job: job,
                                onPause: { queue.pause(job.id) },
                                onResume: { queue.resume(job.id) },
                                onCancel: { queue.cancel(job.id) },
                                onRetry: { queue.retry(job.id) }
                            )
                        }
                    }
                    HStack(spacing: Tokens.Space.x3) {
                        if queue.jobs.contains(where: { $0.state == .finished }) {
                            Button("Clear finished") { queue.dismissFinished() }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.textSec)
                        }
                        if queue.activeCount > 0 {
                            Button("Cancel all") { queue.cancelAll() }
                                .buttonStyle(.plain)
                                .font(Tokens.TypeScale.captionSB)
                                .foregroundStyle(Tokens.Color.danger)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Paste a repository (§63)

struct PasteRepositorySheet: View {
    let onInstall: (ModelDescriptor) -> Void
    let onClose: () -> Void

    @ObservedObject private var metadata = HFMetadataCache.shared
    @State private var input = ""
    @State private var result: HFRepoMetadata?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(
            title: "Add from Hugging Face",
            subtitle: "Paste a repository URL or an org/model identifier.",
            minHeight: 360,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                HStack(spacing: Tokens.Space.x2) {
                    TextField("https://huggingface.co/Qwen/Qwen3-ASR-1.7B", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.TypeScale.body)
                        .onSubmit { inspect() }
                    Button("Inspect model") { inspect() }
                        .primaryAction()
                        .disabled(isLoading || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Fetching repository metadata…")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }

                if let error {
                    InlineBanner(kind: .error, title: "Couldn't read that repository", message: error)
                }

                if let result {
                    VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                        Text(result.repoId)
                            .font(Tokens.TypeScale.title2)
                            .foregroundStyle(Tokens.Color.text)
                            .textSelection(.enabled)
                        HStack(alignment: .top, spacing: Tokens.Space.x4) {
                            MetricCell(label: "Author", value: result.author)
                            MetricCell(label: "Format", value: result.detectedFormat.displayName)
                            MetricCell(label: "Licence", value: result.license?.uppercased() ?? "Unknown",
                                       isUnknown: result.license == nil)
                            MetricCell(label: "Updated", value: result.lastModifiedLabel)
                        }
                        SpecLine(label: "Revision", value: result.sha ?? "—", monospaced: true, copyable: result.sha != nil)

                        let variants = result.variants
                        if variants.isEmpty {
                            InlineBanner(
                                kind: .warning,
                                title: "Nothing installable here",
                                message: ModelRuntimeRegistry.unsupportedReason(for: result.detectedFormat),
                                actionTitle: "Open on Hugging Face",
                                action: { NSWorkspace.shared.open(result.repositoryURL) }
                            )
                        } else {
                            Text("Installable builds")
                                .font(Tokens.TypeScale.headline)
                                .foregroundStyle(Tokens.Color.text)
                            ForEach(variants) { variant in
                                HStack(spacing: Tokens.Space.x3) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(variant.label)
                                            .font(Tokens.TypeScale.caption)
                                            .foregroundStyle(variant.isSupported
                                                             ? Tokens.Color.text : Tokens.Color.textTert)
                                        if let reason = variant.unsupportedReason {
                                            Text(reason)
                                                .font(Tokens.TypeScale.micro)
                                                .foregroundStyle(Tokens.Color.warn)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: Tokens.Space.x3)
                                    Text(variant.sizeLabel)
                                        .font(Tokens.TypeScale.caption).monospacedDigit()
                                        .foregroundStyle(Tokens.Color.textTert)
                                    Button("Inspect") {
                                        onInstall(ModelCatalogService.descriptor(forVariant: variant, in: result))
                                    }
                                    .buttonStyle(.plain)
                                    .font(Tokens.TypeScale.captionSB)
                                    .foregroundStyle(Tokens.Color.accent)
                                    .disabled(!variant.isSupported)
                                }
                                .padding(.vertical, Tokens.Space.x2)
                            }
                        }
                    }
                    .padding(Tokens.Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: nil, elevated: false)
                }
            }
        }
    }

    private func inspect() {
        guard let repoId = HFModelSearch.parseRepoReference(input) else {
            error = "That doesn't look like a Hugging Face repository. Use a URL like https://huggingface.co/org/model, or just org/model."
            return
        }
        isLoading = true
        error = nil
        result = nil
        Task {
            defer { isLoading = false }
            do { result = try await metadata.fetch(repoId) }
            catch { self.error = error.localizedDescription }
        }
    }
}
