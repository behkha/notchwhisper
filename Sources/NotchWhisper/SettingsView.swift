import SwiftUI
import Carbon

/// Settings — a scroll of grouped glass cards on the Aurora canvas (Raycast /
/// Wispr-Flow style), not a system `Form`. All behaviour is unchanged; only
/// the presentation was rebuilt.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @ObservedObject private var updates = UpdateChecker.shared

    @ObservedObject private var connections = LLMConnectionStore.shared
    @ObservedObject private var customModes = CustomModeStore.shared


    var body: some View {
        let _ = theme.theme
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                SectionHeader("Settings", eyebrow: "NotchWhisper")

                dictationGroup
                appearanceGroup
                ShortcutsSection()
                modelGroup
                llmGroup
                updatesGroup
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
    }

    // MARK: General / dictation

    private var dictationGroup: some View {
        SettingsGroup(title: "Dictation") {
            SettingRow(icon: "dot.radiowaves.left.and.right", title: "Live dictation",
                       subtitle: LlamaModelOption.isLlamaId(settings.modelId)
                            ? "Not available with Qwen3-ASR — that model uses hold-to-talk. Switch to a Whisper model for live dictation."
                            : "Type into the focused field as you speak. The Record button, the menu bar and every shortcut become press-to-start / press-to-stop — unless a shortcut pins its own behaviour below.") {
                Toggle("", isOn: $settings.liveDictation)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(LlamaModelOption.isLlamaId(settings.modelId))
                    .onChange(of: settings.liveDictation) { _, _ in
                        NotificationCenter.default.post(name: .dictationChanged, object: nil)
                    }
            }
            SettingRow(icon: "return", title: "New line after each dictation",
                       subtitle: "Press Return once the transcript is inserted.") {
                Toggle("", isOn: $settings.insertNewline).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(icon: "terminal", title: "Paste into terminal programs",
                       subtitle: "Claude Code, Codex, vim and friends read a typed newline as Return, which submits the line. Pasting keeps a multi-line dictation in one piece. A bare shell prompt is still typed, so your clipboard is left alone.") {
                Toggle("", isOn: $settings.pasteIntoTerminalTools).labelsHidden().toggleStyle(.switch)
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

    // MARK: Shortcuts
    //
    // One shortcut per intent — dictate, clean up, start a live session — each
    // with its own overrides. The list and its editor live in ShortcutsView.

    // MARK: Model
    //
    // Settings keeps only what belongs to *behaviour*: which model is active and
    // how it is loaded. Discovery, installation, storage and benchmarking all
    // live on the Models page, so neither surface duplicates the other.

    private var modelGroup: some View {
        let installed = ModelRegistry.shared.installedDescriptors
        return SettingsGroup(title: "Model",
                             footnote: "Install, benchmark, compare and remove models on the Models page.") {
            SettingRow(icon: "cpu", title: "Active model",
                       subtitle: activeModelSubtitle) {
                Picker("", selection: $settings.modelId) {
                    ForEach(installed) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    if !installed.contains(where: { $0.id == settings.modelId }) {
                        Text("\(Self.modelDisplayName(settings.modelId)) · not installed")
                            .tag(settings.modelId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .disabled(state.isDownloading || state.isLoadingModel || settings.autoSelectModel)
                .onChange(of: settings.modelId) { _, _ in
                    NotificationCenter.default.post(name: .modelChanged, object: nil)
                }
            }

            SettingRow(icon: "wand.and.stars", title: "Choose the best model automatically",
                       subtitle: "NotchWhisper picks the best installed model for each dictation, based on your Mac, your language and whether you're on battery. It never changes model while you're recording.") {
                Toggle("", isOn: $settings.autoSelectModel)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            SettingRow(icon: "memorychip", title: "Keep model loaded",
                       subtitle: settings.modelPreload.explanation) {
                Picker("", selection: $settings.modelPreload) {
                    ForEach(Settings.ModelPreloadPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
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
                    Text(installedSummary)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textSec)
                        .lineLimit(2)
                    Spacer(minLength: Tokens.Space.x3)
                    Button("Open Models") { AppDelegate.shared?.showMainWindow() }
                        .buttonStyle(.plain)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)
            }
        }
    }

    private var installedSummary: String {
        let names = ModelRegistry.shared.installedDescriptors.map(\.displayName)
        if names.isEmpty { return "No models installed yet." }
        return "Installed: " + names.joined(separator: ", ")
    }

    /// Display name for any model id, whichever engine it belongs to.
    static func modelDisplayName(_ id: String) -> String {
        ModelRegistry.shared.descriptor(for: id).displayName
    }

    private var activeModelSubtitle: String {
        let model = ModelRegistry.shared.descriptor(for: settings.modelId)
        var parts = [model.capabilities.languageCountLabel]
        if model.resources.diskBytes > 0 { parts.append(model.resources.diskLabel) }
        if !model.capabilities.streaming { parts.append("hold-to-talk only") }
        return parts.joined(separator: " · ")
    }

    // MARK: Updates

    private var updatesGroup: some View {
        SettingsGroup(title: "Updates",
                      footnote: "NotchWhisper follows the \(AppVersion.branch) branch on GitHub. Updating downloads that commit, rebuilds the app and relaunches it — the build takes a few minutes and needs the Xcode command line tools.") {
            SettingRow(icon: "shippingbox", title: "Version",
                       subtitle: AppVersion.displayVersion) {
                Button(updates.isChecking ? "Checking…" : "Check now") {
                    AppDelegate.shared?.checkForUpdates()
                }
                .secondaryAction()
                .disabled(updates.isChecking)
            }

            SettingRow(icon: "arrow.triangle.2.circlepath", title: "Check for updates automatically",
                       subtitle: lastCheckSubtitle) {
                Toggle("", isOn: $updates.autoCheck).labelsHidden().toggleStyle(.switch)
            }

            if updates.pendingUpdate != nil || updateStatusLine != nil {
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    if updates.pendingUpdate != nil {
                        UpdateBanner()
                    } else if let line = updateStatusLine {
                        Text(line).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    }
                }
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, Tokens.Space.x3)
            }
        }
    }

    private var lastCheckSubtitle: String {
        guard let last = updates.lastCheck else { return "Never checked." }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked \(f.localizedString(for: last, relativeTo: Date()))."
    }

    private var updateStatusLine: String? {
        switch updates.status {
        case .upToDate: return "You're on the latest commit."
        case .failed(let message): return message
        default: return nil
        }
    }

    // MARK: AI processing
    //
    // Settings owns the *behaviour* switch and which mode runs. Connections and
    // the modes themselves live on the AI page, so neither surface duplicates
    // the other.

    @ViewBuilder
    private var llmGroup: some View {
        SettingsGroup(title: "Text processing",
                      footnote: settings.llmEnabled ? nil
                        : "Optionally clean up, format, rewrite or summarize transcripts with an AI model — or with a mode you write yourself. Set up a connection on the AI page.") {
            SettingRow(icon: "wand.and.stars", title: "Process with AI",
                       subtitle: "Runs after transcription, before the text is inserted.") {
                Toggle("", isOn: $settings.llmEnabled).labelsHidden().toggleStyle(.switch)
            }

            if settings.llmEnabled {
                connectionRow
                modeRow
                modeDetailRow
            }
        }
    }

    /// Which connection the transcript is sent to — or a prompt to make one.
    @ViewBuilder
    private var connectionRow: some View {
        if let connection = connections.active, connection.isUsable {
            SettingRow(icon: connection.provider.symbolName,
                       tint: connection.isLocal ? Tokens.Color.success : Tokens.Color.warn,
                       title: connection.name,
                       subtitle: "\(connection.subtitle) · \(connection.isLocal ? "stays on this Mac" : "leaves this Mac")") {
                Button("Manage") { openAI(.connections) }
                    .secondaryAction()
            }
        } else {
            SettingRow(icon: "exclamationmark.triangle.fill", tint: Tokens.Color.warn,
                       title: connections.connections.isEmpty ? "No AI connection yet" : "Connection incomplete",
                       subtitle: connections.connections.isEmpty
                        ? "Processing needs a model to talk to — Ollama or LM Studio on this Mac, or a hosted service. Until then transcripts are inserted unchanged."
                        : "The active connection is missing an address or a model name, so processing can't run.") {
                Button(connections.connections.isEmpty ? "Add connection" : "Fix it") { openAI(.connections) }
                    .primaryAction()
            }
        }
    }

    /// The mode picker: the user's modes, plus "no processing".
    private var modeRow: some View {
        SettingRow(icon: customModes.symbol(for: settings.processingMode),
                   title: "Mode",
                   subtitle: customModes.blurb(for: settings.processingMode)) {
            Menu {
                Button(ProcessingMode.offLabel) { settings.processingMode = .off }
                if !customModes.modes.isEmpty {
                    Section("Your modes") {
                        ForEach(customModes.modes) { mode in
                            Button(mode.name) { settings.processingMode = .custom(mode.id) }
                        }
                    }
                }
                Divider()
                Button("New mode…") { openAI(.modes) }
                Button("Manage modes…") { openAI(.modes) }
            } label: {
                Text(customModes.label(for: settings.processingMode))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 200)
        }
    }

    /// What the selected mode will do, in its own words.
    private var modeDetailRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: customModes.symbol(for: settings.processingMode))
                        .font(.system(size: 12)).foregroundStyle(Tokens.Color.accent)
                    Text(customModes.label(for: settings.processingMode))
                        .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.text)
                }
                Text(modeExplanation)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Tokens.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))

            HStack(spacing: Tokens.Space.x4) {
                Button("Write your own mode") { openAI(.modes) }
                    .buttonStyle(.plain).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.accent)
                Button("Manage modes") { openAI(.modes) }
                    .buttonStyle(.plain).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.accent)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }

    /// The mode's own instructions — they are the explanation.
    private var modeExplanation: String {
        switch settings.processingMode {
        case .off:
            return ProcessingMode.offBlurb
        case .custom(let id):
            guard let mode = customModes.mode(id: id) else {
                return "This mode was deleted. Pick another one from the menu above."
            }
            return mode.instructions
        }
    }

    /// Bring the main window forward on the AI page.
    private func openAI(_ tab: AITab) {
        AppDelegate.shared?.showMainWindow()
        NotificationCenter.default.post(name: .openAIPage, object: tab.rawValue)
    }

}
