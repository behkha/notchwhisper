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
        popover.delegate = self
        let panel = MenuPanel(close: { [weak self] in self?.popover.performClose(nil) })
            .environmentObject(state)
            .environmentObject(settings)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = NSSize(width: 320, height: 10)   // SwiftUI drives height

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
        mode.merge(with: status, loading, downloading)
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
            symbol = (state.isDownloading || state.isLoadingModel) ? "arrow.down.circle" : "waveform"
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

private struct MenuPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    let close: () -> Void

    var body: some View {
        let _ = theme.theme
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            // Header
            HStack(spacing: Tokens.Space.x2) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusText)
                        .font(Tokens.TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Color.text)
                    Text("\(ModelRegistry.shared.descriptor(for: settings.modelId).displayName) · \(settings.hotkeyDisplay)")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer()
            }

            if state.isDownloading || state.isLoadingModel {
                ProgressView(value: max(state.isDownloading ? state.displayProgress : state.modelLoadProgress, 0.02))
                    .tint(Tokens.Color.accent)
            }

            // Primary action
            Button {
                NotificationCenter.default.post(name: .toggleRecord, object: nil)
                close()
            } label: {
                Label(primaryTitle, systemImage: primaryIcon)
                    .frame(maxWidth: .infinity)
            }
            .primaryAction(full: true)
            .disabled(primaryDisabled)

            // Quick toggles
            VStack(spacing: 0) {
                toggleRow("dot.radiowaves.left.and.right", "Live dictation", isOn: $settings.liveDictation)
                    .onChange(of: settings.liveDictation) { _, _ in
                        NotificationCenter.default.post(name: .dictationChanged, object: nil)
                    }
                if settings.llmEnabled {
                    Divider().overlay(Tokens.Color.hairline)
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Tokens.Color.accent).frame(width: 18)
                        Text("Processing").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                        Spacer()
                        Picker("", selection: $settings.llmMode) {
                            ForEach(LLMMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 130)
                    }
                    .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 6)
                }
            }
            .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))

            // Latest transcript
            if let rec = history.records.first {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rec.finalText, forType: .string)
                    close()
                } label: {
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                        Text(rec.finalText).lineLimit(1).truncationMode(.tail)
                            .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Space.x2).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy last transcript")
            }

            Divider().overlay(Tokens.Color.hairline)

            // Footer
            HStack(spacing: Tokens.Space.x4) {
                footerButton("Open", "macwindow") { AppDelegate.shared?.showMainWindow(); close() }
                footerButton("Settings", "gearshape") { AppDelegate.shared?.showSettings(); close() }
                Spacer()
                footerButton("Quit", "power") { NSApp.terminate(nil) }
            }
        }
        .padding(Tokens.Space.x4)
        .frame(width: 320)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
    }

    private func toggleRow(_ icon: String, _ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Tokens.Color.accent).frame(width: 18)
            Text(title).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 6)
    }

    private func footerButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(Tokens.TypeScale.micro)
            }
            .foregroundStyle(Tokens.Color.textSec)
        }
        .buttonStyle(.plain)
    }

    private var statusDot: some View {
        Circle().fill(dotColor).frame(width: 8, height: 8)
            .shadow(color: dotColor.opacity(0.6), radius: 3)
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
            case .ready: return settings.liveDictation ? "Ready to dictate" : "Ready — hold to talk"
            case .error: return "Model error"
            default: return "Starting up…"
            }
        case .recording: return "Listening…"
        case .dictating: return "Dictating…"
        case .transcribing: return "Transcribing…"
        case .improving: return "Improving…"
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
    private var primaryDisabled: Bool {
        state.modelStatus != .ready && state.mode == .idle
    }
}
