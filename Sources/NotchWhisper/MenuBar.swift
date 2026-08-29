import AppKit
import SwiftUI
import Combine

/// Secondary, optional menu-bar item: a quick status glance and shortcuts to
/// the main window / settings. The primary interface is the real app window;
/// this is a convenience while working in other apps.
///
/// The icon is a single TEMPLATE SF Symbol that reflects the app state
/// (per ChatGPT consult): monochrome, no animation — the notch is the
/// animation surface. Only error gets a restrained tint.
@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "NotchWhisper")
            btn.image?.isTemplate = true
            btn.action = #selector(showMenu(_:))
            btn.target = self
            btn.sendAction(on: .leftMouseUp)
        }

        // Reflect state on the icon + tooltip.
        state.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                Task { @MainActor in self?.updateIcon(mode) }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(_ mode: NotchMode) {
        guard let btn = statusItem.button else { return }
        let symbol: String
        switch mode {
        case .idle:         symbol = "mic"
        case .recording:    symbol = "mic.fill"
        case .dictating:    symbol = "text.bubble.fill"
        case .transcribing: symbol = "waveform"
        case .improving:    symbol = "wand.and.stars"
        case .done:         symbol = "checkmark.circle"
        case .error:        symbol = "exclamationmark.circle"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotchWhisper")
        // Restrained tint only for error; everything else stays template.
        if mode == .error {
            img?.isTemplate = false
            btn.image = img?.withSymbolConfiguration(
                .init(paletteColors: [NSColor.systemRed]))
        } else {
            img?.isTemplate = true
            btn.image = img
        }
        btn.toolTip = menuTitle
    }

    @objc private func showMenu(_ sender: Any?) {
        let menu = NSMenu()

        let modeItem = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        menu.addItem(modeItem)

        menu.addItem(.separator())

        // Text Processing — lightweight, always-available mode switching so the
        // user never has to open Settings for a one-off dictation.
        if settings.llmEnabled {
            let modeItem = NSMenuItem(title: "Text Processing", action: nil, keyEquivalent: "")
            modeItem.isEnabled = true
            let sub = NSMenu(title: "Text Processing")
            for mode in LLMMode.allCases {
                let item = NSMenuItem(
                    title: mode.displayName,
                    action: #selector(switchMode(_:)),
                    keyEquivalent: ""
                )
                item.tag = LLMMode.allCases.firstIndex(of: mode) ?? 0
                item.state = (settings.llmMode == mode) ? .on : .off
                item.target = self
                sub.addItem(item)
            }
            modeItem.submenu = sub
            menu.addItem(modeItem)
        }

        menu.addItem(NSMenuItem(title: "Open NotchWhisper", action: #selector(openApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        // State-aware: offer only the action that can actually run right now,
        // so the menu never contains a silent no-op.
        switch state.mode {
        case .recording:
            menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRec), keyEquivalent: ""))
        case .dictating:
            menu.addItem(NSMenuItem(title: "Stop Dictation", action: #selector(stopRec), keyEquivalent: ""))
        case .idle, .done, .error:
            let action = settings.liveDictation ? "Start Dictation" : "Start Recording"
            menu.addItem(NSMenuItem(title: action, action: #selector(startRec), keyEquivalent: ""))
        case .transcribing, .improving:
            break  // a recording is already finishing; nothing to toggle
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchWhisper", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach so the menu doesn't re-open on next left-click via sendAction.
        statusItem.menu = nil
    }

    private var menuTitle: String {
        switch state.mode {
        case .idle:
            switch state.modelStatus {
            case .ready:
                return settings.liveDictation
                    ? "Ready · \(settings.hotkeyDisplay) toggles dictation"
                    : "Ready · hold \(settings.hotkeyDisplay)"
            case .loading, .downloading: return "Loading model…"
            case .error(let e): return "Model error: \(e)"
            case .unknown: return "Starting…"
            }
        case .recording:    return "Recording…"
        case .dictating:    return "Dictating… press \(settings.hotkeyDisplay) to stop"
        case .transcribing: return "Transcribing…"
        case .improving:
            return state.statusMessage.isEmpty ? "Improving…" : state.statusMessage
        case .done:         return "Done"
        case .error:        return state.statusMessage.isEmpty ? "Error" : state.statusMessage
        }
    }

    @objc private func openApp() { AppDelegate.shared?.showMainWindow() }
    @objc private func openSettings() { AppDelegate.shared?.showSettings() }
    // Switch the processing mode (menu bar → Text Processing). The active
    // mode is persisted to Settings so the next dictation uses it.
    @objc private func switchMode(_ sender: NSMenuItem) {
        let modes = LLMMode.allCases
        guard modes.indices.contains(sender.tag) else { return }
        settings.llmMode = modes[sender.tag]
    }
    // Both the Start and Stop items route through the unified toggle so they
    // handle either interaction model (hold-to-talk or live dictation) — the
    // menu-bar Stop item otherwise no-ops while dictating.
    @objc private func startRec() { AppDelegate.shared?.toggleRecord() }
    @objc private func stopRec() { AppDelegate.shared?.toggleRecord() }
    @objc private func quit() { NSApp.terminate(nil) }
}
