import Foundation
import Carbon
import ServiceManagement

/// App-wide preferences, persisted in UserDefaults. Thread-safe via @MainActor.
@MainActor final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Key {
        static let modelId        = "modelId"
        static let hotkeyCode     = "hotkeyCode"
        static let hotkeyMods     = "hotkeyModifiers"
        static let autoType       = "autoTypeEnabled"
        static let insertNewline  = "insertNewline"
        static let language       = "language"        // nil = auto-detect
        static let task           = "task"            // "transcribe" | "translate"
        static let launchAtLogin  = "launchAtLogin"
        static let haptic         = "hapticEnabled"
        static let reactiveGlow   = "reactiveGlow"
        static let visualizer     = "visualizerStyle"
    }

    // MARK: - Model
    @Published var modelId: String {
        didSet { defaults.set(modelId, forKey: Key.modelId) }
    }

    // MARK: - Hotkey
    // Default: Right Option (keyCode 61) registered with NO Carbon modifier mask.
    // keyCode 61 already uniquely identifies the right-Option key, so passing the
    // `optionKey` mask (the old default) made the hotkey require "option + right-option"
    // and it never fired. Registering (code 61, mods 0) fires on right-Option alone.
    @Published var hotkeyCode: UInt32 {
        didSet { defaults.set(hotkeyCode, forKey: Key.hotkeyCode) }
    }
    @Published var hotkeyModifiers: UInt32 {
        didSet { defaults.set(hotkeyModifiers, forKey: Key.hotkeyMods) }
    }

    // MARK: - Behavior
    @Published var autoTypeEnabled: Bool {
        didSet { defaults.set(autoTypeEnabled, forKey: Key.autoType) }
    }
    @Published var insertNewline: Bool {
        didSet { defaults.set(insertNewline, forKey: Key.insertNewline) }
    }
    @Published var language: String? {   // nil = auto-detect
        didSet { defaults.set(language, forKey: Key.language) }
    }
    @Published var task: String {        // "transcribe" | "translate"
        didSet { defaults.set(task, forKey: Key.task) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var hapticEnabled: Bool {
        didSet { defaults.set(hapticEnabled, forKey: Key.haptic) }
    }
    /// Voice-reactive notch glow: the island's ambient halo breathes and heats
    /// up with the recorded voice. Off = a calm, static warm glow.
    @Published var reactiveGlow: Bool {
        didSet { defaults.set(reactiveGlow, forKey: Key.reactiveGlow) }
    }
    /// Which audio visualizer style the notch shows while recording /
    /// transcribing (Bar / Wave / Radial / Grid / Aura — LiveKit Agents-UI).
    @Published var visualizerStyle: VisualizerStyle {
        didSet { defaults.set(visualizerStyle.rawValue, forKey: Key.visualizer) }
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)
    /// Mirrors `launchAtLogin` into the system's login-items registry. Called
    /// after the toggle changes and once at startup to reconcile.
    /// Note: register()/unregister() are idempotent — calling register() when
    /// already registered is a no-op, so no status pre-check is needed (and a
    /// pre-check on .notFound would wrongly skip first-time registration).
    func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            fputs("NotchWhisper: SMAppService error: \(error)\n", stderr)
        }
    }

    // MARK: - Init
    private init() {
        let d = UserDefaults.standard
        self.modelId        = d.string(forKey: Key.modelId) ?? WhisperModelOption.default.id

        // Right-Option default: code 61 with NO modifier mask (see Hotkey note above).
        let storedCode = d.integer(forKey: Key.hotkeyCode)
        let storedMods = d.integer(forKey: Key.hotkeyMods)
        let code = UInt32(storedCode == 0 ? 61 : storedCode)
        var mods = UInt32(storedMods == 0 ? 0 : storedMods)
        // Migrate the old buggy default: right-Option registered WITH the option mask
        // never fired. If that's what was stored, drop the modifier so it works.
        if code == 61, mods == UInt32(optionKey) {
            mods = 0
            d.set(0, forKey: Key.hotkeyMods)
        }
        self.hotkeyCode = code
        self.hotkeyModifiers = mods
        self.autoTypeEnabled = d.object(forKey: Key.autoType) != nil ? d.bool(forKey: Key.autoType) : true
        self.insertNewline   = d.bool(forKey: Key.insertNewline)
        self.language        = d.string(forKey: Key.language)
        self.task            = d.string(forKey: Key.task) ?? "transcribe"
        self.launchAtLogin   = d.object(forKey: Key.launchAtLogin) != nil ? d.bool(forKey: Key.launchAtLogin) : true
        self.hapticEnabled   = d.object(forKey: Key.haptic) != nil ? d.bool(forKey: Key.haptic) : true
        self.reactiveGlow    = d.object(forKey: Key.reactiveGlow) != nil ? d.bool(forKey: Key.reactiveGlow) : true
        self.visualizerStyle = VisualizerStyle(raw: d.string(forKey: Key.visualizer))
    }

    // MARK: - Helpers
    var hotkeyDisplay: String {
        var parts: [String] = []
        if hotkeyModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkeyModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotkeyModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkeyModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if let name = keyName(code: Int(hotkeyCode)) {
            parts.append(name)
        } else {
            parts.append("key \(hotkeyCode)")
        }
        return parts.joined(separator: "")
    }

    private func keyName(code: Int) -> String? {
        let map: [Int: String] = [
            61: "Right ⌥", 58: "⌥", 55: "⌘", 54: "Right ⌘",
            56: "⇧", 60: "Right ⇧", 59: "⌃", 57: "Caps",
            49: "Space", 36: "↩", 48: "Tab", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return map[code]
    }
}
