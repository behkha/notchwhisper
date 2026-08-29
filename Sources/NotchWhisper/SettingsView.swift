import SwiftUI
import Carbon

/// Settings window content. Holds the hotkey capture and the model picker /
/// download — exactly the two things the user asked to live here. A small
/// behavior section (auto-type, language, translate) is included because it is
/// cheap and useful, but hotkey + model are the primary controls.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @State private var capturing = false
    @State private var captureLabel = "Press a key…"

    // Local LLM section state
    @State private var showingAPIKey = false
    @State private var apiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                generalSection
                Divider().foregroundStyle(Tokens.Color.separator)
                appearanceSection
                Divider().foregroundStyle(Tokens.Color.separator)
                hotkeySection
                Divider().foregroundStyle(Tokens.Color.separator)
                modelSection
                Divider().foregroundStyle(Tokens.Color.separator)
                llmSection
            }
            .padding(Tokens.Space.x6)
            .frame(width: 520)
        }
        .background(Tokens.Color.bg)
        .tint(Tokens.Color.accent)
    }

    // MARK: General
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("General")
            Toggle(isOn: $settings.liveDictation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live dictation")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Transcribe continuously and type into the focused text field as you speak. The hotkey becomes a toggle: press once to start, press again to stop. Turn off to keep hold-to-talk.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: settings.liveDictation) { _, _ in
                NotificationCenter.default.post(name: .dictationChanged, object: nil)
            }

            Toggle(isOn: $settings.launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Start NotchWhisper automatically when you log in. It lives quietly in the menu bar until you hold the hotkey.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: settings.launchAtLogin) { _, _ in
                settings.applyLaunchAtLogin()
            }
        }
    }

    // MARK: Appearance
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Appearance")
            themePicker
            Toggle(isOn: $settings.reactiveGlow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice-reactive notch glow")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("While recording, the notch's ambient glow breathes and heats up with your voice. Turn off for a calm, static glow.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            visualizerPicker
        }
    }

    // MARK: Theme color (Settings → Appearance)
    /// A row of swatch buttons — one per theme. Selecting one recolors the
    /// whole app live: UI accent, notch glow, and the Wave/Aura visualizers.
    private var themePicker: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Theme color")
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
            HStack(spacing: Tokens.Space.x3) {
                ForEach(Tokens.Theme.allCases) { theme in
                    let isSelected = settings.themeColor == theme
                    Button {
                        settings.themeColor = theme
                    } label: {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 26, height: 26)
                            .overlay(
                                // Selection ring, offset outward so it reads
                                // even against a same-colored background.
                                Circle()
                                    .strokeBorder(isSelected ? Tokens.Color.text : .clear,
                                                  lineWidth: 1.5)
                                    .frame(width: 32, height: 32)
                            )
                            .overlay(
                                Circle().strokeBorder(Tokens.Color.separator,
                                                      lineWidth: Tokens.Border.hair)
                            )
                    }
                    .buttonStyle(Pressable(scale: 0.85))
                    .help("Theme: \(theme.displayName)")
                    .accessibilityLabel("Theme color \(theme.displayName)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
                Spacer()
            }
            Text("\(settings.themeColor.displayName) — recolors the app, the notch glow, and the visualizers.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Visualizer style (LiveKit Agents-UI family)
    private var visualizerPicker: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Notch visualizer")
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)

            Picker("Notch visualizer", selection: $settings.visualizerStyle) {
                ForEach(VisualizerStyle.allCases) { style in
                    Text(style.display).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.visualizerStyle.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            // Live preview on a black island strip, driven by a simulated voice.
            VisualizerPreview(style: settings.visualizerStyle)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(.black)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Border.hair)
                )
        }
    }

    // MARK: Hotkey
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Hotkey")
            Text(settings.liveDictation
                ? "Press this key anywhere to start live dictation; press again to stop — your speech is typed as you speak."
                : "Press and hold this key anywhere to record; release to transcribe and type.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Tokens.Space.x3) {
                Button {
                    armCapture()
                } label: {
                    Text(capturing ? captureLabel : settings.hotkeyDisplay)
                        .font(Tokens.TypeScale.title2)
                        .frame(minWidth: 120, minHeight: 44)
                        .foregroundStyle(capturing ? Tokens.Color.record : Tokens.Color.text)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .fill(capturing ? Tokens.Color.record.opacity(0.12) : Tokens.Color.fillQuiet)
                        )
                }
                .buttonStyle(Pressable(scale: 0.97))

                Button("Reset to Right ⌥") {
                    settings.hotkeyCode = 61
                    settings.hotkeyModifiers = 0
                    NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .foregroundStyle(Tokens.Color.textSec)
                .font(Tokens.TypeScale.callout)

                Spacer()
            }
        }
        .onDisappear { cancelCapture() }
    }

    // MARK: Model
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Model")
            Text("Local Whisper models are downloaded from Hugging Face and run on-device. Larger models are more accurate but slower.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Active model", selection: $settings.modelId) {
                ForEach(WhisperModelOption.all) { m in
                    Text("\(m.display)  ·  \(m.size)  ·  \(m.quality)")
                        .tag(m.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.modelId) { _, _ in
                NotificationCenter.default.post(name: .modelChanged, object: nil)
            }

            // Downloaded models + download action.
            HStack(spacing: Tokens.Space.x2) {
                Text(downloadedSummary)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer()
                if state.isDownloading {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: state.displayProgress) {
                            Text(state.downloadLabel)
                                .font(Tokens.TypeScale.caption)
                        }
                        if !state.downloadDetailText.isEmpty {
                            Text(state.downloadDetailText)
                                .font(Tokens.TypeScale.micro)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 240)
                } else {
                    Button {
                        AppDelegate.shared?.requestDownload(modelId: settings.modelId)
                    } label: {
                        Text(WhisperModelOption.find(id: settings.modelId).folderName == currentFolder
                             ? "Reload" : "Download")
                        .font(Tokens.TypeScale.captionSB)
                    }
                    .buttonStyle(Pressable(scale: 0.97))
                    .foregroundStyle(Tokens.Color.accent)
                    .help("Download or reload the selected model")
                }
            }
        }
    }

    @State private var currentFolder: String = ""

    private var downloadedSummary: String {
        let local = AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []
        if local.isEmpty { return "No models downloaded yet." }
        return "On disk: " + local.map { WhisperModelOption.find(id: $0).display }.joined(separator: ", ")
    }

        // MARK: - Local LLM

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Local LLM")

            if !settings.llmEnabled {
                llmFirstTimeGuidance
            }

            Toggle(isOn: $settings.llmEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable text processing")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Process transcribed text with a local AI model before inserting it. Turn this on to start.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if settings.llmEnabled {
                llmSourceSection
            }
        }
    }

    // MARK: First-time guidance

    private var llmFirstTimeGuidance: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Improve your transcriptions with a local AI model")
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.text)
            Text("NotchWhisper can optionally clean up, format, rewrite, or summarize your transcriptions using a language model running on your Mac. Connect NotchWhisper to an existing local LLM application with an OpenAI-compatible API — such as Ollama, LM Studio, or Unsloth — and your text never has to leave your machine.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.x4)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    // MARK: Server config

    @ViewBuilder
    private var llmSourceSection: some View {
        llmServerSource

        llmModePicker

        if settings.llmMode == .custom {
            llmCustomInstruction
        }
    }


    // MARK: Server source

    private var llmServerSource: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("Model")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
            TextField("e.g. llama3", text: $settings.llmServerModel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .textCase(.lowercase)

            Text("Endpoint")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
            TextField("e.g. http://localhost:11434/v1", text: $settings.llmServerEndpoint)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            llmAPIKeyRow

            llmActiveModelInfo

            Text("Text is sent to the configured local endpoint — not to the cloud.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            llmTestConnectionButton

            if let result = connectionTestResult {
                Text(result)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(result.contains("Connected") ? Tokens.Color.success : Tokens.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var llmAPIKeyRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("API key")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Button {
                    showingAPIKey.toggle()
                    if showingAPIKey {
                        apiKeyInput = Keychain.get(account: ServerKeychainAccount.llmAPIKey) ?? ""
                    }
                } label: {
                    Text(showingAPIKey ? "Apply" : "Change")
                        .font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .foregroundStyle(Tokens.Color.accent)
            }
            if showingAPIKey {
                HStack {
                    SecureField("Enter API key (leave empty if not required)", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Save") {
                        if apiKeyInput.isEmpty {
                            Keychain.set(nil, for: ServerKeychainAccount.llmAPIKey)
                        } else {
                            Keychain.set(apiKeyInput, for: ServerKeychainAccount.llmAPIKey)
                        }
                        showingAPIKey = false
                    }
                    .buttonStyle(Pressable(scale: 0.97))
                    .foregroundStyle(Tokens.Color.accent)
                }
            }
        }
    }

    private var llmActiveModelInfo: some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Tokens.Color.success)
            Text("Active model: \(settings.llmServerModel.isEmpty ? "(not set)" : settings.llmServerModel)")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
            if !settings.llmServerEndpoint.isEmpty {
                Text("at \(settings.llmServerEndpoint)")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
            }
        }
        .padding(.top, Tokens.Space.x1)
    }

    private var llmTestConnectionButton: some View {
        Button {
            Task { await llmTestConnection() }
        } label: {
            HStack {
                if isTestingConnection {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .controlSize(.small)
                }
                Text(isTestingConnection ? "Testing…" : "Test connection")
                    .font(Tokens.TypeScale.captionSB)
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
        .foregroundStyle(Tokens.Color.accent)
        .disabled(settings.llmServerEndpoint.isEmpty || isTestingConnection)
    }

    private func llmTestConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        let endpoint = settings.llmServerEndpoint
        let apiKey = Keychain.get(account: ServerKeychainAccount.llmAPIKey)
        do {
            try await LLMServerClient.testConnection(endpoint: endpoint, apiKey: apiKey)
            await MainActor.run {
                connectionTestResult = "Connected successfully"
            }
        } catch {
            await MainActor.run {
                connectionTestResult = "Unable to connect. Check that your local LLM application is running and that the address is correct."
            }
        }
        isTestingConnection = false
    }

    // MARK: Mode picker

    private var llmModePicker: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Processing mode")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)

            Picker(selection: $settings.llmMode) {
                ForEach(LLMMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.displayName).foregroundStyle(Tokens.Color.text)
                        Text(mode.blurb).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    }
                    .tag(mode)
                }
            } label: {
                Text("Processing mode")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    // MARK: Custom instruction

    private var llmCustomInstruction: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Custom instruction")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
            TextEditor(text: $settings.customPrompt)
                .font(.system(.body).monospaced())
                .frame(height: 120)
                .background(Tokens.Color.elevated, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).stroke(Tokens.Color.separator, lineWidth: 1))
            Text("Write the instruction that should be applied to the transcription. Example: \"Rewrite this as a concise professional email.\"")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(Tokens.TypeScale.title2)
            .foregroundStyle(Tokens.Color.text)
    }

    // MARK: Hotkey capture (local monitor while armed)
    private func armCapture() {
        capturing = true
        captureLabel = "Press a key…"
        var monitor: Any?
        // Keycodes for the dedicated modifier keys. When the user presses one of
        // these alone we register it as a standalone hotkey (mods 0) — e.g. the
        // right-Option key (61) fires on its own press, and must NOT also carry
        // the `optionKey` mask (which would require "option + right-option").
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
            return nil // swallow the key
        }
    }

    private func cancelCapture() {
        capturing = false
    }
}
