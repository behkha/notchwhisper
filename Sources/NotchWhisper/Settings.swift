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
        static let modelPreload   = "modelPreloadPolicy"
        static let autoSelectModel = "autoSelectModel"
        static let hotkeyCode     = "hotkeyCode"
        static let hotkeyMods     = "hotkeyModifiers"
        static let autoType       = "autoTypeEnabled"
        static let insertNewline  = "insertNewline"
        static let liveDictation  = "liveDictation"
        static let language       = "language"        // nil = auto-detect
        static let task           = "task"            // "transcribe" | "translate"
        static let launchAtLogin  = "launchAtLogin"
        static let haptic         = "hapticEnabled"
        static let reactiveGlow   = "reactiveGlow"
        static let visualizer     = "visualizerStyle"
        static let themeColor     = Tokens.Theme.defaultsKey
        // Local LLM post-processing
        static let llmEnabled      = "llmEnabled"
        static let llmMode         = "llmMode"            // LLMMode raw
        static let llmCustomPrompt = "llmCustomPrompt"
        static let llmEndpoint     = "llmServerEndpoint"
        static let llmServerModel  = "llmServerModel"
    }

    // MARK: - Model
    @Published var modelId: String {
        didSet { defaults.set(modelId, forKey: Key.modelId) }
    }

    /// When the active model's weights are brought into memory (§48). Keeping a
    /// model resident starts dictation instantly but holds its memory the whole
    /// time the app is running.
    enum ModelPreloadPolicy: String, CaseIterable, Identifiable {
        case automatic          // load at launch, keep resident (default)
        case keepLoaded         // load at launch and never release
        case onFirstDictation   // don't touch memory until the user speaks

        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic:        return "Automatically"
            case .keepLoaded:       return "Keep active model loaded"
            case .onFirstDictation: return "Load on first dictation"
            }
        }
        var explanation: String {
            switch self {
            case .automatic:
                return "Loads the model shortly after launch and keeps it resident."
            case .keepLoaded:
                return "Always resident — dictation starts instantly, at the cost of the model's memory."
            case .onFirstDictation:
                return "Frees memory until you first speak; the first dictation waits for the model to load."
            }
        }
        /// Whether the model is brought in at launch.
        var preloadsAtLaunch: Bool { self != .onFirstDictation }
    }

    @Published var modelPreload: ModelPreloadPolicy {
        didSet { defaults.set(modelPreload.rawValue, forKey: Key.modelPreload) }
    }

    /// Let the app pick the best installed model for each dictation (§38).
    /// Never applied while a recording is in flight.
    @Published var autoSelectModel: Bool {
        didSet { defaults.set(autoSelectModel, forKey: Key.autoSelectModel) }
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
    /// Live dictation — transcribe continuously and type into the focused field
    /// *as you speak*. While ON the hotkey / Record button becomes a toggle
    /// (press to start, press again to stop) instead of hold-to-talk.
    @Published var liveDictation: Bool {
        didSet { defaults.set(liveDictation, forKey: Key.liveDictation) }
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
    /// Accent theme (Settings → Appearance). Recolors the whole app — UI
    /// accent, notch glow, and the Wave/Aura visualizer colors.
    @Published var themeColor: Tokens.Theme {
        didSet {
            defaults.set(themeColor.rawValue, forKey: Key.themeColor)
            Tokens.ThemeManager.shared.theme = themeColor
        }
    }

    // MARK: - Local LLM post-processing
    /// Master switch. When OFF the pipeline is exactly as before:
    /// Voice → Transcribe → Insert at cursor.
    @Published var llmEnabled: Bool {
        didSet { defaults.set(llmEnabled, forKey: Key.llmEnabled) }
    }
    /// Default processing mode (quick switch from the menu bar overrides it
    /// for a single dictation).
    @Published var llmMode: LLMMode {
        didSet { defaults.set(llmMode.rawValue, forKey: Key.llmMode) }
    }
    /// Custom instruction shown when Custom mode is selected.
    @Published var customPrompt: String {
        didSet { defaults.set(customPrompt, forKey: Key.llmCustomPrompt) }
    }
    /// Server base URL, e.g. `http://localhost:11434/v1` or
    /// `http://127.0.0.1:1234/v1`. Empty until the user configures one.
    @Published var llmServerEndpoint: String {
        didSet { defaults.set(llmServerEndpoint, forKey: Key.llmEndpoint) }
    }
    /// Model served by that endpoint (name only; no path).
    @Published var llmServerModel: String {
        didSet { defaults.set(llmServerModel, forKey: Key.llmServerModel) }
    }
    /// Convenience: the transcript is processed only when LLM processing is
    /// enabled AND the active mode is not passthrough.
    var llmActiveForCurrentMode: Bool {
        llmEnabled && !llmMode.isPassthrough
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
        self.modelPreload   = ModelPreloadPolicy(rawValue: d.string(forKey: Key.modelPreload) ?? "")
            ?? .automatic
        self.autoSelectModel = d.bool(forKey: Key.autoSelectModel)

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
        self.liveDictation   = d.object(forKey: Key.liveDictation) != nil ? d.bool(forKey: Key.liveDictation) : false
        self.language        = d.string(forKey: Key.language)
        self.task            = d.string(forKey: Key.task) ?? "transcribe"
        self.launchAtLogin   = d.object(forKey: Key.launchAtLogin) != nil ? d.bool(forKey: Key.launchAtLogin) : true
        self.hapticEnabled   = d.object(forKey: Key.haptic) != nil ? d.bool(forKey: Key.haptic) : true
        self.reactiveGlow    = d.object(forKey: Key.reactiveGlow) != nil ? d.bool(forKey: Key.reactiveGlow) : true
        self.visualizerStyle = VisualizerStyle(raw: d.string(forKey: Key.visualizer))
        self.themeColor      = Tokens.Theme(rawValue: d.string(forKey: Key.themeColor) ?? "") ?? .ember
        // Local LLM (all defaults OFF / passthrough so the app works exactly
        // as before until the user enables post-processing).
        self.llmEnabled      = d.object(forKey: Key.llmEnabled) != nil ? d.bool(forKey: Key.llmEnabled) : false
        self.llmMode         = LLMMode(rawValue: d.string(forKey: Key.llmMode) ?? "") ?? .cleanup
        self.customPrompt      = d.string(forKey: Key.llmCustomPrompt) ?? ""
        self.llmServerEndpoint = d.string(forKey: Key.llmEndpoint) ?? ""
        self.llmServerModel    = d.string(forKey: Key.llmServerModel) ?? ""
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
