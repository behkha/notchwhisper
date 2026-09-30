import SwiftUI
import Carbon

/// The Settings panes, in sidebar order. Deep links (`showSettings(pane:)`)
/// and the stored last-open pane both use the raw value.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, microphone, voice, shortcuts, model, ai, appearance, feedback, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .microphone: return "Microphone"
        case .voice:      return "Voice Detection"
        case .shortcuts:  return "Shortcuts"
        case .model:      return "Model"
        case .ai:         return "AI Processing"
        case .appearance: return "Appearance"
        case .feedback:   return "Sounds & Alerts"
        case .updates:    return "Updates"
        }
    }

    var summary: String {
        switch self {
        case .general:    return "How your words reach the app you're working in."
        case .microphone: return "Which input NotchWhisper listens to."
        case .voice:      return "Keep accidental presses from typing text you never said."
        case .shortcuts:  return "The keys that start a dictation, anywhere on your Mac."
        case .model:      return "The speech engine, and how it stays ready."
        case .ai:         return "Clean up, format or rewrite a transcript before it's inserted."
        case .appearance: return "Accent color, and how the notch looks while you speak."
        case .feedback:   return "Sounds, haptics and notifications."
        case .updates:    return "Keep NotchWhisper current with its source."
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .microphone: return "mic.fill"
        case .voice:      return "waveform"
        case .shortcuts:  return "keyboard.fill"
        case .model:      return "cpu.fill"
        case .ai:         return "sparkles"
        case .appearance: return "paintpalette.fill"
        case .feedback:   return "bell.badge.fill"
        case .updates:    return "arrow.triangle.2.circlepath"
        }
    }

    /// System Settings-style tile colors: fixed per category, independent of
    /// the accent theme, so the sidebar reads the same for everyone.
    var tile: SwiftUI.Color {
        switch self {
        case .general:    return SwiftUI.Color(red: 0.56, green: 0.57, blue: 0.61)
        case .microphone: return SwiftUI.Color(red: 1.00, green: 0.27, blue: 0.36)
        case .voice:      return SwiftUI.Color(red: 0.66, green: 0.36, blue: 0.92)
        case .shortcuts:  return SwiftUI.Color(red: 0.38, green: 0.42, blue: 0.50)
        case .model:      return SwiftUI.Color(red: 0.10, green: 0.52, blue: 1.00)
        case .ai:         return SwiftUI.Color(red: 0.40, green: 0.38, blue: 0.95)
        case .appearance: return SwiftUI.Color(red: 0.18, green: 0.66, blue: 0.86)
        case .feedback:   return SwiftUI.Color(red: 1.00, green: 0.25, blue: 0.21)
        case .updates:    return SwiftUI.Color(red: 0.20, green: 0.72, blue: 0.40)
        }
    }

    static let defaultsKey = "settingsPane"
}

/// Settings — System Settings' shape on the Graphite canvas: a vibrant
/// sidebar of colored category tiles beside one pane of grouped rows at a
/// time. All behaviour is unchanged; only the presentation was rebuilt.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @ObservedObject private var updates = UpdateChecker.shared

    @ObservedObject private var connections = LLMConnectionStore.shared
    @ObservedObject private var customModes = CustomModeStore.shared

    @AppStorage(SettingsPane.defaultsKey) private var paneRaw: String = SettingsPane.general.rawValue
    @Namespace private var paneSelection

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }

    var body: some View {
        let _ = theme.theme
        HStack(spacing: 0) {
            sidebar
            Hairline(vertical: true).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                    paneHeader
                    paneContent
                        .environment(\.settingsGroupTitleHidden, pane != .general)
                }
                .padding(.horizontal, Tokens.Space.x8)
                .padding(.top, Tokens.Space.x10)
                .padding(.bottom, Tokens.Space.x10)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(pane)
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AuroraBackground())
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsPane.allCases) { item in
                let selected = item == pane
                Button {
                    withAnimation(Tokens.Motion.select(reduceMotion: Tokens.A11y.reduceMotion)) { paneRaw = item.rawValue }
                } label: {
                    HStack(spacing: Tokens.Space.x2 + 2) {
                        IconTile(item.icon, tint: item.tile, size: 22, style: .solid)
                        Text(item.title)
                            .font(Tokens.TypeScale.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Tokens.Color.text : Tokens.Color.text.opacity(0.86))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 32)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .fill(Tokens.Color.selectionFill)
                                .matchedGeometryEffect(id: "pane", in: paneSelection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, Tokens.Layout.titlebarInset)
        .frame(width: 214)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    // MARK: Pane

    private var paneHeader: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x4) {
            IconTile(pane.icon, tint: pane.tile, size: 44, style: .solid)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(Tokens.TypeScale.title1)
                    .foregroundStyle(Tokens.Color.text)
                Text(pane.summary)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general:
            dictationGroup
            languageGroup
            systemGroup
        case .microphone: MicrophoneSettingsGroup()
        case .voice:      voiceGroup
        case .shortcuts:  ShortcutsSection()
        case .model:      modelGroup
        case .ai:         llmGroup
        case .appearance: appearanceGroup
        case .feedback:   feedbackGroup
        case .updates:    updatesGroup
        }
    }

    // MARK: General

    private var dictationGroup: some View {
        SettingsGroup(title: "Dictation") {
            SettingRow(icon: "dot.radiowaves.left.and.right", title: "Live dictation",
                       subtitle: !ModelEngine.supportsLive(settings.modelId)
                            ? "Not available with Qwen3-ASR — that model uses hold-to-talk. Switch to a Whisper, Parakeet or Apple Speech model for live dictation."
                            : "Type into the focused field as you speak. The Record button, the menu bar and every shortcut become press-to-start / press-to-stop — unless a shortcut pins its own behaviour.") {
                Toggle("", isOn: $settings.liveDictation)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!ModelEngine.supportsLive(settings.modelId))
                    .onChange(of: settings.liveDictation) { _, _ in
                        NotificationCenter.default.post(name: .dictationChanged, object: nil)
                    }
            }
            SettingRow(icon: "text.cursor", title: "Correct as you speak",
                       subtitle: "Types each word the moment it's heard and fixes the last few in place as the sentence goes on, like live captions. Off types each phrase once it's final. Stops correcting as soon as you type, click or switch apps.") {
                Toggle("", isOn: $settings.liveRewrites)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!settings.liveDictation || !ModelEngine.supportsLive(settings.modelId))
            }
            SettingRow(icon: "keyboard", title: "Type into the focused app",
                       subtitle: "Off keeps every dictation in Transcripts only — nothing is typed anywhere.") {
                Toggle("", isOn: $settings.autoTypeEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(icon: "return", title: "New line after each dictation",
                       subtitle: "Press Return once the transcript is inserted.") {
                Toggle("", isOn: $settings.insertNewline).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(icon: "terminal", title: "Paste into terminal programs",
                       subtitle: "Claude Code, Codex, vim and friends read a typed newline as Return, which submits the line. Pasting keeps a multi-line dictation in one piece. A bare shell prompt is still typed, so your clipboard is left alone.") {
                Toggle("", isOn: $settings.pasteIntoTerminalTools).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var languageGroup: some View {
        SettingsGroup(title: "Language") {
            SettingRow(icon: "globe", title: "Spoken language",
                       subtitle: "Auto-detect handles one language at a time; naming it is faster and more accurate. A shortcut can pick a different one.") {
                Menu {
                    ForEach(LanguageChoice.all, id: \.code) { choice in
                        Button(choice.name) { settings.language = choice.code.isEmpty ? nil : choice.code }
                    }
                } label: {
                    Text(LanguageChoice.label(for: settings.language)).lineLimit(1)
                }
                .popupMenuStyle()
                .frame(maxWidth: 180)
            }
            SettingRow(icon: "character.book.closed", title: "Translate to English",
                       subtitle: "Whisper writes English whatever language you speak, instead of transcribing it as spoken.") {
                Toggle("", isOn: $settings.translateToEnglish).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var systemGroup: some View {
        SettingsGroup(title: "System") {
            SettingRow(icon: "power", title: "Launch at login",
                       subtitle: "Start quietly in the menu bar when you log in.") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.launchAtLogin) { _, _ in settings.applyLaunchAtLogin() }
            }
        }
    }

    // MARK: Voice detection (spec 04)

    private var voiceGroup: some View {
        SettingsGroup(title: "Voice detection",
                      footnote: "Whisper invents text when it hears nothing — \"Thank you.\" on a silent recording is the classic. These checks keep an accidental press from typing a sentence you never said.") {
            SettingRow(icon: "waveform.slash", title: "Ignore silent recordings",
                       subtitle: "A recording with no speech in it is discarded instead of transcribed. The menu bar offers to transcribe it anyway.") {
                Toggle("", isOn: $settings.vadIgnoreSilent).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(icon: "scissors", title: "Trim silence before transcribing",
                       subtitle: "Cuts the quiet before and after you speak. Faster, and a little more accurate.") {
                Toggle("", isOn: $settings.vadTrimSilence).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                Text("Sensitivity")
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text)
                Picker("", selection: $settings.vadSensitivity) {
                    ForEach(VoiceActivityDetector.Sensitivity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(settings.vadSensitivity.blurb)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x4)
            SettingRow(icon: "timer", title: "Minimum press length",
                       subtitle: "Shorter presses of a hold-to-talk shortcut are ignored as accidental.") {
                Picker("", selection: $settings.minPressMilliseconds) {
                    Text("Off").tag(0)
                    Text("250 ms").tag(250)
                    Text("500 ms").tag(500)
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
            SettingRow(icon: "stop.circle", title: "Stop live dictation after silence",
                       subtitle: "Ends a live session by itself once you've been quiet this long.") {
                Picker("", selection: $settings.liveAutoStopSeconds) {
                    Text("Off").tag(0)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
        }
    }

    // MARK: Feedback

    private var feedbackGroup: some View {
        SettingsGroup(title: "Feedback") {
            SettingRow(icon: "speaker.wave.2", title: "Sounds",
                       subtitle: "A soft tick when the mic opens, a pop when it closes, a low note if something fails.") {
                Toggle("", isOn: $settings.soundFeedback).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(icon: "hand.tap", title: "Haptic feedback",
                       subtitle: "A tap when recording starts (Force Touch trackpads).") {
                Toggle("", isOn: $settings.hapticEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(icon: "bell.badge", title: "Notifications",
                       subtitle: UserNotifier.isAvailable
                        ? "A system notification when a model finishes installing, a download fails, or an AI pass falls back to your original text — only while NotchWhisper is in the background."
                        : "Available when NotchWhisper runs as a packaged app.") {
                Toggle("", isOn: $settings.notificationsEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!UserNotifier.isAvailable)
            }
        }
    }

    // MARK: Appearance

    private var appearanceGroup: some View {
        SettingsGroup(title: "Appearance") {
            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Accent color")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Spacer()
                    Text(settings.themeColor.displayName)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .contentTransition(.opacity)
                }
                HStack(spacing: Tokens.Space.x3) {
                    ForEach(Tokens.Theme.allCases) { t in
                        ThemeSwatch(theme: t, selected: settings.themeColor == t) {
                            withAnimation(Tokens.Motion.quick) { settings.themeColor = t }
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text("Colors the primary action, the current selection, the notch glow and the visualizers — nothing else.")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x4)

            SettingRow(icon: "sparkles", title: "Voice-reactive notch glow",
                       subtitle: "The notch halo breathes and warms with your voice.") {
                Toggle("", isOn: $settings.reactiveGlow).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                Text("Notch visualizer")
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text)
                Picker("", selection: $settings.visualizerStyle) {
                    ForEach(VisualizerStyle.allCases) { Text($0.display).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                VisualizerPreview(style: settings.visualizerStyle)
                    .frame(height: 72)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(.black))
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Tokens.Color.black(0.4), Tokens.Color.white(0.06)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    )
                Text(settings.visualizerStyle.blurb)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x4)
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
                    .toggleStyle(.switch).controlSize(.small)
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
                    Button("Open Models") {
                        AppDelegate.shared?.showMainWindow()
                        NotificationCenter.default.post(name: .openMainPage, object: MainView.Nav.models.rawValue)
                    }
                    .quietAction()
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
                Toggle("", isOn: $updates.autoCheck).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            SettingRow(icon: "bell.badge", title: "Notify me when an update is available",
                       subtitle: !UserNotifier.isAvailable
                        ? "Available when NotchWhisper runs as a packaged app."
                        : updates.autoCheck
                            ? "A system notification once per new build, even while NotchWhisper is in front. Click it to review and install."
                            : "Turn on automatic checks to be notified.") {
                Toggle("", isOn: $updates.notifyWhenAvailable).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!updates.autoCheck || !UserNotifier.isAvailable)
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
        return "Last checked \(last.relativeLabel)."
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
                Toggle("", isOn: $settings.llmEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
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
            .popupMenuStyle()
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

            HStack(spacing: Tokens.Space.x2) {
                Button("Write your own mode") { openAI(.modes) }
                    .quietAction()
                Button("Manage modes") { openAI(.modes) }
                    .quietAction()
                Spacer(minLength: 0)
            }
            .padding(.leading, -7)
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

/// One accent swatch: a lit sphere of the theme color; the chosen one wears a
/// ring and a centre pip.
private struct ThemeSwatch: View {
    let theme: Tokens.Theme
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.accent.opacity(1), theme.accent.opacity(0.78)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 18))
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if selected {
                    Circle().fill(theme.onAccent.opacity(0.85)).frame(width: 7, height: 7)
                }
            }
            .frame(width: 24, height: 24)
            .padding(3)
            .overlay(
                Circle().strokeBorder(selected ? theme.accent.opacity(0.9) : (hovering ? Tokens.Color.hairlineStrong : .clear),
                                      lineWidth: 1.5)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(theme.displayName)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
