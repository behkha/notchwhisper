import SwiftUI
import Carbon

/// Settings — a scroll of grouped glass cards on the Aurora canvas (Raycast /
/// Wispr-Flow style), not a system `Form`. All behaviour is unchanged; only
/// the presentation was rebuilt.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @State private var capturing = false
    @State private var captureLabel = "Press a key…"

    @State private var showingAPIKey = false
    @State private var apiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String?
    @State private var showAllModes = false

    var body: some View {
        let _ = theme.theme
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                SectionHeader("Settings", eyebrow: "NotchWhisper")

                dictationGroup
                appearanceGroup
                hotkeyGroup
                modelGroup
                llmGroup
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
        .onDisappear { cancelCapture() }
    }

    // MARK: General / dictation

    private var dictationGroup: some View {
        SettingsGroup(title: "Dictation") {
            SettingRow(icon: "dot.radiowaves.left.and.right", title: "Live dictation",
                       subtitle: "Type into the focused field as you speak. The hotkey becomes press-to-start / press-to-stop.") {
                Toggle("", isOn: $settings.liveDictation)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: settings.liveDictation) { _, _ in
                        NotificationCenter.default.post(name: .dictationChanged, object: nil)
                    }
            }
            SettingRow(icon: "return", title: "New line after each dictation",
                       subtitle: "Press Return once the transcript is inserted.") {
                Toggle("", isOn: $settings.insertNewline).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(icon: "power", title: "Launch at login",
                       subtitle: "Start quietly in the menu bar when you log in.") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: settings.launchAtLogin) { _, _ in settings.applyLaunchAtLogin() }
            }
            SettingRow(icon: "hand.tap", title: "Haptic feedback",
                       subtitle: "A tap when recording starts (Force Touch trackpads).") {
                Toggle("", isOn: $settings.hapticEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Appearance

    private var appearanceGroup: some View {
        SettingsGroup(title: "Appearance") {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                Text("Accent theme")
                    .font(Tokens.TypeScale.body.weight(.medium))
                    .foregroundStyle(Tokens.Color.text)
                HStack(spacing: Tokens.Space.x3) {
                    ForEach(Tokens.Theme.allCases) { t in
                        let sel = settings.themeColor == t
                        Button { settings.themeColor = t } label: {
                            Circle().fill(t.accent).frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: sel ? 2 : 0).padding(-3))
                                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(t.displayName)
                    }
                    Spacer()
                }
                Text("Recolors the app, the notch glow and the visualizers.")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)

            SettingRow(icon: "sparkles", title: "Voice-reactive notch glow",
                       subtitle: "The notch halo breathes and heats with your voice.") {
                Toggle("", isOn: $settings.reactiveGlow).labelsHidden().toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                Text("Notch visualizer")
                    .font(Tokens.TypeScale.body.weight(.medium))
                    .foregroundStyle(Tokens.Color.text)
                Picker("", selection: $settings.visualizerStyle) {
                    ForEach(VisualizerStyle.allCases) { Text($0.display).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(settings.visualizerStyle.blurb)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                VisualizerPreview(style: settings.visualizerStyle)
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(.black))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
        }
    }

    // MARK: Hotkey

    private var hotkeyGroup: some View {
        SettingsGroup(title: "Hotkey",
                      footnote: settings.liveDictation
                        ? "Press this key anywhere to start live dictation; press again to stop."
                        : "Hold this key anywhere to record; release to transcribe and type.") {
            HStack(spacing: Tokens.Space.x3) {
                IconTile("keyboard", tint: Tokens.Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trigger key").font(Tokens.TypeScale.body.weight(.medium)).foregroundStyle(Tokens.Color.text)
                    Text(capturing ? "Listening for a key…" : "Click the key cap to change")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                }
                Spacer()
                Button { armCapture() } label: {
                    Text(capturing ? captureLabel : settings.hotkeyDisplay)
                        .font(Tokens.TypeScale.title2)
                        .foregroundStyle(capturing ? Tokens.Color.record : Tokens.Color.text)
                        .frame(minWidth: 96, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .fill(capturing ? Tokens.Color.record.opacity(0.14) : Tokens.Color.fillQuiet))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    settings.hotkeyCode = 61; settings.hotkeyModifiers = 0
                    NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.Color.textSec)
                .help("Reset to Right ⌥")
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
        }
    }

    // MARK: Model

    private var modelGroup: some View {
        let downloaded = downloadedModelIds
        return SettingsGroup(title: "Model",
                             footnote: "Manage the full catalog — with a compatibility check for this Mac — on the Models page.") {
            SettingRow(icon: "cpu", title: "Active model",
                       subtitle: "\(WhisperModelOption.find(id: settings.modelId).lang) · \(ModelCatalog.shared.sizeLabel(for: WhisperModelOption.find(id: settings.modelId)))") {
                Picker("", selection: $settings.modelId) {
                    ForEach(downloaded, id: \.self) { id in
                        Text(WhisperModelOption.find(id: id).display).tag(id)
                    }
                    if !downloaded.contains(settings.modelId) {
                        Text("\(WhisperModelOption.find(id: settings.modelId).display) · not downloaded").tag(settings.modelId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .disabled(state.isDownloading || state.isLoadingModel)
                .onChange(of: settings.modelId) { _, _ in
                    NotificationCenter.default.post(name: .modelChanged, object: nil)
                }
            }

            if state.isDownloading || state.isLoadingModel {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack {
                        Text(state.isDownloading
                             ? (state.downloadLabel.isEmpty ? "Downloading…" : state.downloadLabel)
                             : (state.modelLoadPhase.isEmpty ? "Loading…" : state.modelLoadPhase))
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                        Spacer()
                        Text("\(Int(((state.isDownloading ? state.displayProgress : state.modelLoadProgress) * 100).rounded()))%")
                            .font(Tokens.TypeScale.caption).monospacedDigit().foregroundStyle(Tokens.Color.textTert)
                    }
                    ProgressView(value: max(state.isDownloading ? state.displayProgress : state.modelLoadProgress, 0.02))
                        .tint(Tokens.Color.accent)
                    if state.isDownloading, !state.downloadDetailText.isEmpty {
                        Text(state.downloadDetailText).font(Tokens.TypeScale.micro).monospacedDigit()
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)
            } else {
                HStack {
                    Text(downloadedSummary).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    Spacer()
                    Button(downloaded.contains(settings.modelId) ? "Reload" : "Download") {
                        AppDelegate.shared?.requestDownload(modelId: settings.modelId)
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)
            }
        }
    }

    private var downloadedModelIds: [String] {
        let folders = AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []
        var ids = folders.map { WhisperModelOption.bareId($0) }
        if !ids.contains(WhisperModelOption.default.id) { ids.append(WhisperModelOption.default.id) }
        return Array(Set(ids)).sorted {
            WhisperModelOption.find(id: $0).englishWERValue < WhisperModelOption.find(id: $1).englishWERValue
        }
    }
    private var downloadedSummary: String {
        let local = AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []
        if local.isEmpty { return "No models downloaded yet." }
        return "On disk: " + local.map { WhisperModelOption.find(id: $0).display }.joined(separator: ", ")
    }

    // MARK: Local LLM

    @ViewBuilder
    private var llmGroup: some View {
        SettingsGroup(title: "Text processing",
                      footnote: settings.llmEnabled ? nil
                        : "Optionally clean up, format, rewrite or summarize transcripts with a local model (Ollama, LM Studio, Unsloth…). Text never leaves your Mac.") {
            SettingRow(icon: "wand.and.stars", title: "Process with a local AI model",
                       subtitle: "Runs after transcription, before the text is inserted.") {
                Toggle("", isOn: $settings.llmEnabled).labelsHidden().toggleStyle(.switch)
            }

            if settings.llmEnabled {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    labeledField("Model name", text: $settings.llmServerModel, placeholder: "llama3")
                    labeledField("Endpoint", text: $settings.llmServerEndpoint, placeholder: "http://localhost:11434/v1")
                    apiKeyRow
                    HStack(spacing: Tokens.Space.x3) {
                        Button { Task { await llmTestConnection() } } label: {
                            HStack(spacing: 6) {
                                if isTestingConnection { ProgressView().controlSize(.small) }
                                Text(isTestingConnection ? "Testing…" : "Test connection")
                            }
                        }
                        .secondaryAction()
                        .disabled(settings.llmServerEndpoint.isEmpty || isTestingConnection)
                        if let r = connectionTestResult {
                            Label(r, systemImage: r.contains("Connected") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(r.contains("Connected") ? Tokens.Color.success : Tokens.Color.danger)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)

                modePickerRow
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 8)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("API key").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                Button(showingAPIKey ? "Done" : "Change") {
                    showingAPIKey.toggle()
                    if showingAPIKey { apiKeyInput = Keychain.get(account: ServerKeychainAccount.llmAPIKey) ?? "" }
                }
                .buttonStyle(.plain).font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.accent)
            }
            if showingAPIKey {
                HStack {
                    SecureField("Leave empty if not required", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 8)
                        .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                    Button("Save") {
                        Keychain.set(apiKeyInput.isEmpty ? nil : apiKeyInput, for: ServerKeychainAccount.llmAPIKey)
                        showingAPIKey = false
                    }
                    .buttonStyle(.plain).foregroundStyle(Tokens.Color.accent)
                }
            }
        }
    }

    private var modePickerRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("Processing mode").font(Tokens.TypeScale.body.weight(.medium)).foregroundStyle(Tokens.Color.text)
            Picker("", selection: $settings.llmMode) {
                ForEach(LLMMode.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)

            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: settings.llmMode.symbolName).font(.system(size: 12)).foregroundStyle(Tokens.Color.accent)
                    Text(settings.llmMode.displayName).font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.text)
                }
                Text(settings.llmMode.explanation)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                if let ex = settings.llmMode.example {
                    VStack(alignment: .leading, spacing: 3) {
                        exampleLine("mic", Tokens.Color.textTert, ex.before)
                        exampleLine("arrow.turn.down.right", Tokens.Color.accent, ex.after)
                    }
                    .padding(Tokens.Space.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Color.fillQuieter, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                }
            }
            .padding(Tokens.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))

            Button(showAllModes ? "Hide mode reference" : "How the modes work") {
                withAnimation(Tokens.Motion.ease) { showAllModes.toggle() }
            }
            .buttonStyle(.plain).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.accent)

            if showAllModes {
                VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                    ForEach(LLMMode.allCases) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(m.displayName, systemImage: m.symbolName)
                                .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.text)
                            Text(m.explanation).font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textTert)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if settings.llmMode == .custom {
                Text("Custom instruction").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                TextEditor(text: $settings.customPrompt)
                    .font(.system(.body).monospaced())
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .padding(Tokens.Space.x2)
                    .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }

    private func exampleLine(_ icon: String, _ tint: SwiftUI.Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.x2) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(tint).padding(.top, 2)
            Text(text).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.Color.textSec).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Logic (unchanged)

    private func llmTestConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        let endpoint = settings.llmServerEndpoint
        let apiKey = Keychain.get(account: ServerKeychainAccount.llmAPIKey)
        do {
            try await LLMServerClient.testConnection(endpoint: endpoint, apiKey: apiKey)
            connectionTestResult = "Connected successfully"
        } catch {
            connectionTestResult = "Unable to connect. Check that your local LLM app is running and the address is correct."
        }
        isTestingConnection = false
    }

    private func armCapture() {
        capturing = true
        captureLabel = "Press a key…"
        var monitor: Any?
        let modifierKeyCodes: Set<Int> = [58, 61, 55, 54, 56, 60, 59, 57]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let code = Int(event.keyCode)
            if modifierKeyCodes.contains(code) {
                settings.hotkeyCode = UInt32(code)
                settings.hotkeyModifiers = 0
            } else {
                let mods = UInt32(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
                settings.hotkeyCode = UInt32(code)
                settings.hotkeyModifiers = mods
            }
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            if let m = monitor { NSEvent.removeMonitor(m) }
            capturing = false
            return nil
        }
    }

    private func cancelCapture() { capturing = false }
}
