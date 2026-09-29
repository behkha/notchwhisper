import AppKit
import SwiftUI
import Combine

/// Menu-bar item: a template SF Symbol reflecting app state, and a bespoke
/// SwiftUI panel (an `NSPopover`) on click — a compact control surface, the
/// Wispr-Flow-style dropdown, instead of a plain `NSMenu`.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()
    private let popover = NSPopover()

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        // The panel is designed for one ground; without this the popover's
        // own chrome (material, arrow) follows a light system appearance.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let panel = MenuPanel(close: { [weak self] in self?.popover.performClose(nil) })
            .environmentObject(state)
            .environmentObject(settings)
        // The hosting controller must publish SwiftUI's measured size as its
        // `preferredContentSize`, otherwise NSPopover is shown at whatever
        // `contentSize` we guessed, computes its anchor from THAT box, and then
        // grows — which pushed the panel up through the menu bar and off the top
        // of the screen. `.preferredContentSize` makes the popover know its real
        // height before it is placed.
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "NotchWhisper")
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        let mode = state.$mode.map { _ in () }
        let status = state.$modelStatus.map { _ in () }
        let loading = state.$isLoadingModel.map { _ in () }
        let downloading = state.$isDownloading.map { _ in () }
        let meeting = state.$meetingRecording.map { _ in () }
        mode.merge(with: status, loading, downloading, meeting)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in Task { @MainActor in guard let self else { return }; self.updateIcon() } }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        guard let btn = statusItem.button else { return }
        let symbol: String
        switch state.mode {
        case .idle:
            symbol = state.meetingRecording ? "record.circle"
                : (state.isDownloading || state.isLoadingModel) ? "arrow.down.circle" : "waveform"
        case .recording:    symbol = "waveform.badge.mic"
        case .dictating:    symbol = "text.bubble.fill"
        case .transcribing: symbol = "waveform"
        case .improving:    symbol = "wand.and.stars"
        case .done:         symbol = "checkmark.circle.fill"
        case .error:        symbol = "exclamationmark.circle.fill"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotchWhisper")
        if state.mode == .error {
            img?.isTemplate = false
            btn.image = img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else if state.mode == .recording || state.mode == .dictating {
            img?.isTemplate = false
            btn.image = img?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
        } else {
            img?.isTemplate = true
            btn.image = img
        }
        btn.toolTip = "NotchWhisper"
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - The SwiftUI panel

/// The menu-bar panel, laid out like Control Center: a status header, one
/// large record module, a module of quick controls, the shortcut legend, and
/// a quiet footer — all on the popover's own dark material.
private struct MenuPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var modes = CustomModeStore.shared
    @ObservedObject private var connections = LLMConnectionStore.shared
    @ObservedObject private var profiles = AppProfileStore.shared
    @ObservedObject private var hotkeys = HotkeyBindingStore.shared
    let close: () -> Void

    var body: some View {
        let _ = theme.theme
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.isDownloading || state.isLoadingModel {
                ProgressView(value: max(state.isDownloading ? state.displayProgress : state.modelLoadProgress, 0.02))
                    .tint(Tokens.Color.accent)
                    .padding(.horizontal, 4)
            }

            recordModule

            controlsModule

            shortcutList

            UpdateBanner(compact: true)

            if let rec = history.records.first { lastTranscript(rec) }

            Hairline().padding(.horizontal, 4)

            footer
        }
        .padding(12)
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        // The popover makes its window key, which paints the system focus ring
        // on the first focusable control (the record button). Every other
        // surface in the app suppresses it too.
        .focusEffectDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Tokens.Space.x2 + 2) {
            StatusDot(color: dotColor, size: 7,
                      pulsing: state.mode == .recording || state.mode == .dictating)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(Tokens.TypeScale.headline)
                    .foregroundStyle(Tokens.Color.text)
                Text(ModelRegistry.shared.descriptor(for: settings.modelId).displayName)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .lineLimit(1)
            }
            Spacer()
            Text("NotchWhisper")
                .font(Tokens.TypeScale.caption.weight(.medium))
                .foregroundStyle(Tokens.Color.textQuat)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Record module

    private var recordModule: some View {
        let live = state.mode == .recording || state.mode == .dictating
        return Button {
            NotificationCenter.default.post(name: .toggleRecord, object: nil)
            close()
        } label: {
            HStack(spacing: Tokens.Space.x3) {
                ZStack {
                    Circle()
                        .fill(live
                              ? AnyShapeStyle(LinearGradient(colors: [Tokens.Color.record, Tokens.Color.recordDark],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Tokens.Color.accentGradient))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.02)],
                                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .shadow(color: (live ? Tokens.Color.record : Tokens.Color.accent).opacity(0.3), radius: 6, y: 2)
                    Image(systemName: primaryIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(live ? .white : Tokens.Color.onAccent)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTitle)
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)
                    if let primary = hotkeys.primary, !live, primary.effectiveActivation != .editSelection {
                        HStack(spacing: 5) {
                            Text(primary.effectiveActivation == .toggleLive ? "or press" : "or hold")
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textTert)
                            KeyCap(text: primary.display, compact: true)
                        }
                    } else if live {
                        Text("Click to stop")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModuleButtonStyle())
        .disabled(primaryDisabled)
    }

    // MARK: Controls module

    private var controlsModule: some View {
        VStack(spacing: 0) {
            MicrophoneMenuBarRow()
            divider
            toggleRow("dot.radiowaves.left.and.right", "Live dictation", isOn: $settings.liveDictation)
                .onChange(of: settings.liveDictation) { _, _ in
                    NotificationCenter.default.post(name: .dictationChanged, object: nil)
                }
            if state.meetingRecording {
                divider
                Button {
                    Task { await MeetingStore.shared.stop() }
                    close()
                } label: {
                    HStack(spacing: Tokens.Space.x2 + 2) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 13)).foregroundStyle(Tokens.Color.record).frame(width: 18)
                        Text("Stop meeting recording")
                            .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
                        Spacer(minLength: 0)
                        Text(AudioFileImport.durationLabel(seconds: MeetingStore.shared.elapsed))
                            .font(Tokens.TypeScale.caption).monospacedDigit().foregroundStyle(Tokens.Color.textTert)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            if state.discardedRecordingAvailable {
                // The silence gate dropped the last capture (spec 04); this
                // is the escape hatch for a whisperer or a quiet mic.
                divider
                Button {
                    AppDelegate.shared?.transcribeDiscardedRecording()
                    close()
                } label: {
                    HStack(spacing: Tokens.Space.x2 + 2) {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.system(size: 13)).foregroundStyle(Tokens.Color.warn).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Transcribe anyway")
                                .font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
                            Text("The last recording sounded silent and was skipped.")
                                .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            if profiles.enabledCount > 0 {
                divider
                toggleRow("app.badge", "Ignore app profile once",
                          isOn: $profiles.bypassNextDictation)
            }
            if settings.llmEnabled {
                divider
                HStack(spacing: Tokens.Space.x2 + 2) {
                    Image(systemName: modes.symbol(for: settings.processingMode))
                        .font(.system(size: 13)).foregroundStyle(Tokens.Color.textSec).frame(width: 18)
                    Text("Mode").font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
                    Spacer()
                    Menu {
                        Button(ProcessingMode.offLabel) { settings.processingMode = .off }
                        if !modes.modes.isEmpty {
                            Section("Your modes") {
                                ForEach(modes.modes) { mode in
                                    Button(mode.name) { settings.processingMode = .custom(mode.id) }
                                }
                            }
                        }
                        Divider()
                        Button("Manage modes…") {
                            AppDelegate.shared?.showMainWindow()
                            NotificationCenter.default.post(name: .openAIPage, object: AITab.modes.rawValue)
                            close()
                        }
                    } label: {
                        Text(modes.label(for: settings.processingMode)).lineLimit(1)
                    }
                    .popupMenuStyle()
                    .controlSize(.small)
                    .frame(maxWidth: 150)
                }
                .padding(.horizontal, 10).frame(minHeight: 36)

                if settings.llmNeedsConnection {
                    divider
                    Button {
                        AppDelegate.shared?.showMainWindow()
                        NotificationCenter.default.post(name: .openAIPage, object: AITab.connections.rawValue)
                        close()
                    } label: {
                        HStack(spacing: Tokens.Space.x2 + 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12)).foregroundStyle(Tokens.Color.warn).frame(width: 18)
                            Text("Add an AI connection to run modes")
                                .font(Tokens.TypeScale.callout).foregroundStyle(Tokens.Color.textSec)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.Color.textQuat)
                        }
                        .padding(.horizontal, 10).frame(minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .modulePlate()
    }

    private var divider: some View {
        Hairline().padding(.leading, 38)
    }

    /// Every shortcut with its key drawn, so "which key does what" is
    /// answerable without opening Settings. Nothing here fires a recording —
    /// a hold-to-talk binding has no meaning as a click.
    @ViewBuilder
    private var shortcutList: some View {
        let enabled = hotkeys.bindings.filter { $0.enabled && $0.keyCode != 0 }
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Shortcuts")
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer()
                Button("Edit") { AppDelegate.shared?.openSettings(.shortcuts); close() }
                    .quietAction()
            }
            if enabled.isEmpty {
                Text("No shortcut set — use the button above.")
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            } else {
                ForEach(enabled.prefix(5)) { binding in
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: binding.effectiveActivation.symbolName)
                            .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert).frame(width: 16)
                        Text(binding.name.isEmpty ? "Untitled" : binding.name)
                            .font(Tokens.TypeScale.callout).foregroundStyle(Tokens.Color.textSec)
                            .lineLimit(1)
                        Spacer(minLength: Tokens.Space.x2)
                        KeyCap(text: binding.display, compact: true)
                    }
                }
                if enabled.count > 5 {
                    Text("+\(enabled.count - 5) more")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func lastTranscript(_ rec: TranscriptRecord) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rec.finalText, forType: .string)
            close()
        } label: {
            HStack(spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last transcript")
                        .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                    Text(rec.finalText).lineLimit(1).truncationMode(.tail)
                        .font(Tokens.TypeScale.callout).foregroundStyle(Tokens.Color.textSec)
                }
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help("Copy last transcript")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Button("Open NotchWhisper") { AppDelegate.shared?.showMainWindow(); close() }
                .quietAction(tint: Tokens.Color.text)
            Spacer()
            IconButton(systemImage: "square.grid.2x2", help: "App profiles", size: 26) {
                AppDelegate.shared?.showMainWindow()
                NotificationCenter.default.post(name: .openAppsPage, object: nil)
                close()
            }
            IconButton(systemImage: "gearshape", help: "Settings", size: 26) {
                AppDelegate.shared?.showSettings(); close()
            }
            IconButton(systemImage: "power", help: "Quit NotchWhisper", size: 26) { NSApp.terminate(nil) }
        }
        .padding(.leading, -3)
    }

    private func toggleRow(_ icon: String, _ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Tokens.Space.x2 + 2) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Tokens.Color.textSec).frame(width: 18)
            Text(title).font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 10).frame(minHeight: 36)
    }

    private var dotColor: SwiftUI.Color {
        switch state.mode {
        case .idle: return state.modelStatus == .ready ? Tokens.Color.success : Tokens.Color.warn
        case .recording, .dictating: return Tokens.Color.record
        case .transcribing, .improving: return Tokens.Color.warn
        case .done: return Tokens.Color.success
        case .error: return Tokens.Color.danger
        }
    }
    private var statusText: String {
        switch state.mode {
        case .idle:
            if state.isDownloading { return "Downloading model…" }
            if state.isLoadingModel { return "Loading model…" }
            switch state.modelStatus {
            case .ready: return settings.liveDictation ? "Ready to dictate" : "Ready"
            case .error: return "Model error"
            default: return settings.modelPreload.preloadsAtLaunch ? "Starting up…" : "Loads on first use"
            }
        case .recording: return "Listening…"
        case .dictating: return "Dictating…"
        case .transcribing: return "Transcribing…"
        case .improving: return state.statusMessage.isEmpty ? "Improving…" : state.statusMessage
        case .done: return "Done"
        case .error: return "Something went wrong"
        }
    }
    private var primaryTitle: String {
        switch state.mode {
        case .recording: return "Stop recording"
        case .dictating: return "Stop dictation"
        default: return settings.liveDictation ? "Start dictation" : "Start recording"
        }
    }
    private var primaryIcon: String {
        (state.mode == .recording || state.mode == .dictating) ? "stop.fill" : "mic.fill"
    }
    /// Recording can start whenever a model is resident — or installed but not
    /// loaded yet, because starting a recording loads it (the hotkey path does
    /// the same). Only a model that is loading, downloading, failed or absent
    /// blocks the button.
    private var primaryDisabled: Bool {
        guard state.mode == .idle else { return false }
        switch state.modelStatus {
        case .ready: return false
        case .unknown: return ModelRegistry.shared.installedIds.isEmpty
        default: return true
        }
    }
}

// MARK: - Module styling

private extension View {
    /// A Control Center module: a lit translucent plate on the popover material.
    func modulePlate() -> some View {
        self
            .background(Tokens.Color.white(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Tokens.Color.white(0.10), Tokens.Color.white(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The record module: a module plate that brightens on hover and dims when
/// the engine can't take a recording yet.
private struct ModuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        ModuleBody(configuration: configuration, isEnabled: isEnabled)
    }
    private struct ModuleBody: View {
        let configuration: ButtonStyleConfiguration
        let isEnabled: Bool
        @ViewState private var hovering = false
        var body: some View {
            configuration.label
                .background(Tokens.Color.white(hovering && isEnabled ? 0.10 : 0.06),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Tokens.Color.white(0.10), Tokens.Color.white(0.03)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .onHover { hovering = $0 }
                .animation(Tokens.Motion.hover, value: hovering)
        }
    }
}

/// A plain row that washes on hover — for tappable rows inside a module.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @ViewState private var hovering = false
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Tokens.Color.hoverFill : .clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}
