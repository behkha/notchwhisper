import Foundation
import Carbon
import CoreGraphics
import SwiftUI

// MARK: - Hotkey binding
//
// One shortcut for plain dictation, another for clean prose, another for a
// live session. Every field below the shortcut itself is an OPTIONAL override
// with the same shape as `AppProfile`: nil means "inherit", so a binding that
// only changes the mode leaves everything else alone.
//
// Precedence, when a binding and an app profile both have an opinion: the
// BINDING wins. Pressing a specific key is a more explicit statement of intent
// than "I happen to be in Slack". See specs/00-FLAGS.md §5 — this is the
// *settings* merge (more specific overrides), not the restrictions merge.

struct HotkeyBinding: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var enabled: Bool
    /// nil = inherit the global "Live dictation" switch, like every other
    /// override below. Stored under the same JSON key it always had, so a file
    /// written by an older build still decodes — as an explicit choice, which
    /// `migrateActivationToInherit()` then relaxes for bindings that never made
    /// one.
    var activation: Activation?

    /// Stored as the `ProcessingMode` storage key so an unknown or deleted
    /// selection degrades to "inherit" instead of failing the whole archive.
    var processingModeKey: String?
    var llmEnabled: Bool?
    /// false = capture to history only, never type into the focused field.
    var autoType: Bool?
    var insertNewline: Bool?
    /// Whisper language code ("en", "de"…). nil = inherit; "" is treated as
    /// auto-detect so the editor can offer an explicit "Auto-detect" choice.
    var language: String?

    var createdAt: Date
    var updatedAt: Date

    /// How the key behaves while held.
    ///
    ///  · holdToTalk — press and hold to record, release to transcribe.
    ///  · toggleLive — press once to START a continuous live session that types
    ///    as you speak, press again to STOP.
    enum Activation: String, Codable, CaseIterable, Identifiable {
        case holdToTalk
        case toggleLive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .holdToTalk: return "Hold to talk"
            case .toggleLive: return "Live session"
            }
        }

        var blurb: String {
            switch self {
            case .holdToTalk: return "Hold the shortcut to record, release to transcribe and insert."
            case .toggleLive: return "Press once to start dictating continuously, press again to stop."
            }
        }

        var symbolName: String {
            switch self {
            case .holdToTalk: return "hand.tap"
            case .toggleLive: return "dot.radiowaves.left.and.right"
            }
        }
    }

    init(id: UUID = UUID(), name: String = "",
         keyCode: UInt32 = 61, carbonModifiers: UInt32 = 0,
         enabled: Bool = true, activation: Activation? = nil,
         processingMode: ProcessingMode? = nil, llmEnabled: Bool? = nil,
         autoType: Bool? = nil, insertNewline: Bool? = nil,
         language: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.enabled = enabled
        self.activation = activation
        self.processingModeKey = processingMode?.storageKey
        self.llmEnabled = llmEnabled
        self.autoType = autoType
        self.insertNewline = insertNewline
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var processingMode: ProcessingMode? {
        get { processingModeKey.flatMap { ProcessingMode(storageKey: $0) } }
        set { processingModeKey = newValue?.storageKey }
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How this shortcut actually behaves: its own choice if it made one, and
    /// otherwise whatever the global "Live dictation" switch says. Turning that
    /// switch on is what makes an ordinary dictate shortcut press-to-start /
    /// press-to-stop — the whole point of the setting, and something a stored
    /// `activation` froze out for every binding that already existed.
    @MainActor var effectiveActivation: Activation {
        activation ?? (Settings.shared.liveDictation ? .toggleLive : .holdToTalk)
    }

    /// How many settings this binding actually changes — drives the row summary.
    var overrideCount: Int {
        var n = 0
        if activation != nil { n += 1 }
        if processingModeKey != nil { n += 1 }
        if llmEnabled != nil { n += 1 }
        if autoType != nil { n += 1 }
        if insertNewline != nil { n += 1 }
        if language != nil { n += 1 }
        return n
    }

    // MARK: Trigger shape
    //
    // The three vocabularies (`HotkeyCodes`) again, but per binding, so the
    // monitor can build its table from plain data and the editor can reason
    // about conflicts without installing anything.

    /// The Carbon mask the trigger KEY itself contributes — never also required.
    var ownMask: UInt32 { HotkeyCodes.carbonMask(forModifierKeyCode: Int(keyCode)) }

    /// Modifiers that must be held IN ADDITION to the trigger key.
    var requiredCarbon: UInt32 { carbonModifiers & ~ownMask }

    var requiredFlags: CGEventFlags { HotkeyCodes.cgFlags(carbon: requiredCarbon) }

    /// Set when the trigger key is itself a modifier — the flag it raises.
    var triggerFlag: CGEventFlags? { HotkeyCodes.flag(forKeyCode: Int(keyCode)) }

    /// A bare modifier: right-Option with nothing else required.
    var isBareModifier: Bool { triggerFlag != nil && requiredCarbon == 0 }

    /// More required modifiers = more specific. `⌃⌥D` beats a bare `D`.
    var specificity: Int { requiredFlags.rawValue.nonzeroBitCount }

    /// Two bindings are the SAME shortcut when the key and the effective
    /// modifiers match — `carbonModifiers` may differ only in the trigger
    /// key's own bit, which the monitor strips anyway.
    func sameShortcut(as other: HotkeyBinding) -> Bool {
        keyCode == other.keyCode && requiredCarbon == other.requiredCarbon
    }

    @MainActor var display: String {
        Settings.hotkeyDisplay(code: keyCode, modifiers: carbonModifiers)
    }

    // MARK: Starters
    //
    // Offered on the Shortcuts list. These only PREFILL the editor — nothing is
    // installed behind the user's back, the same rule `CustomMode.templates`
    // and `AppProfile.suggestions` follow.

    struct Starter: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var symbolName: String
        var activation: Activation?
        var processingModeKey: String?
        var hint: String
    }

    static let starters: [Starter] = [
        .init(name: "Dictate", symbolName: "mic",
              activation: nil,        // follows the global Live dictation switch
              processingModeKey: ProcessingMode.off.storageKey,
              hint: "Types exactly what you said."),
        .init(name: "Clean prose", symbolName: "wand.and.stars",
              activation: .holdToTalk,
              processingModeKey: ProcessingMode.custom(CustomMode.Seed.cleanUp).storageKey,
              hint: "Runs your Clean Up mode over the transcript."),
        .init(name: "Live session", symbolName: "dot.radiowaves.left.and.right",
              activation: .toggleLive, processingModeKey: nil,
              hint: "Press to start, press again to stop."),
    ]

    static let iconChoices = [
        "mic", "wand.and.stars", "dot.radiowaves.left.and.right", "note.text",
        "bubble.left.and.bubble.right", "envelope", "terminal",
        "chevron.left.forwardslash.chevron.right", "list.bullet.clipboard",
        "globe", "bolt", "star",
    ]

    /// Well-known system shortcuts. We cannot reliably enumerate what the
    /// system actually holds, so this is a WARNING list, never a refusal.
    static let systemShortcuts: [(code: UInt32, carbon: UInt32, name: String)] = [
        (49,  UInt32(cmdKey),                      "⌘Space (Spotlight)"),
        (49,  UInt32(controlKey),                  "⌃Space (Input source)"),
        (48,  UInt32(cmdKey),                      "⌘Tab (App switcher)"),
        (48,  UInt32(controlKey),                  "⌃Tab (Tab switcher)"),
        (126, UInt32(controlKey),                  "⌃↑ (Mission Control)"),
        (125, UInt32(controlKey),                  "⌃↓ (App windows)"),
        (123, UInt32(controlKey),                  "⌃← (Move a space left)"),
        (124, UInt32(controlKey),                  "⌃→ (Move a space right)"),
        (53,  UInt32(cmdKey) | UInt32(optionKey),  "⌘⌥Esc (Force Quit)"),
        (12,  UInt32(cmdKey),                      "⌘Q (Quit)"),
        (13,  UInt32(cmdKey),                      "⌘W (Close window)"),
        (0,   UInt32(cmdKey),                      "⌘A (Select all)"),
        (9,   UInt32(cmdKey),                      "⌘V (Paste)"),
    ]
}

// MARK: - Store

@MainActor final class HotkeyBindingStore: ObservableObject {
    static let shared = HotkeyBindingStore()

    @Published private(set) var bindings: [HotkeyBinding] = []

    private let fileManager = FileManager.default
    private var url: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/hotkeys.json")
    }

    private init() { load() }

    // MARK: Access

    func binding(id: UUID) -> HotkeyBinding? { bindings.first { $0.id == id } }

    var enabledCount: Int { bindings.filter { $0.enabled }.count }

    /// The shortcut the home screen advertises. nil when nothing is armed —
    /// which the UI must say out loud rather than promising a dead key.
    var primary: HotkeyBinding? { bindings.first { $0.enabled && $0.keyCode != 0 } }

    /// One line of "how do I dictate", honest about there being no shortcut.
    func hint(long: Bool) -> String {
        guard let primary else {
            return long
                ? "No shortcut is set. Use the Record button below, or add a shortcut in Settings."
                : "No shortcut set — use the Record button."
        }
        switch primary.effectiveActivation {
        case .toggleLive:
            return long
                ? "Press \(primary.display) to start live dictation — press again to stop. Words appear as you speak."
                : "Press \(primary.display), speak, then press again to stop."
        case .holdToTalk:
            return long
                ? "Hold \(primary.display) anywhere and talk. Release to transcribe and type."
                : "Hold \(primary.display) anywhere and start talking."
        }
    }

    /// What the monitor installs: enabled bindings, most specific FIRST, so a
    /// `⌃⌥D` binding wins over a bare `D` on the same event.
    var installable: [HotkeyBinding] {
        bindings.filter { $0.enabled }.sorted { $0.specificity > $1.specificity }
    }

    // MARK: CRUD

    func add(_ binding: HotkeyBinding) {
        bindings.append(binding)
        persist()
    }

    func update(_ binding: HotkeyBinding) {
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        var updated = binding
        updated.updatedAt = Date()
        bindings[index] = updated
        persist()
    }

    func remove(_ binding: HotkeyBinding) {
        bindings.removeAll { $0.id == binding.id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for binding: HotkeyBinding) {
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        bindings[index].enabled = enabled
        bindings[index].updatedAt = Date()
        persist()
    }

    func uniqueName(basedOn name: String) -> String {
        let taken = Set(bindings.map { $0.name.lowercased() })
        var candidate = name
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: Conflicts
    //
    // Pure functions of the binding list, so the editor can show them live and
    // a test can assert them without installing an event tap.

    /// An existing binding with exactly the same key + modifiers. Rejected.
    func duplicate(of candidate: HotkeyBinding) -> HotkeyBinding? {
        bindings.first { $0.id != candidate.id && $0.sameShortcut(as: candidate) }
    }

    /// A binding that will swallow this one, or that this one will swallow.
    ///
    /// The monitor allows ONE session at a time and picks the most specific
    /// trigger that matches. A BARE modifier therefore fires the moment that
    /// modifier goes down, before any combination containing it can complete —
    /// so `⌥` shadows `⌥D`, not the other way round. (The monitor's 40 ms
    /// debounce narrows the window; it does not close it.)
    func shadowWarning(for candidate: HotkeyBinding) -> String? {
        guard candidate.enabled else { return nil }
        let others = bindings.filter { $0.id != candidate.id && $0.enabled }

        if let flag = candidate.triggerFlag, candidate.isBareModifier {
            // This one is bare — it shadows every binding requiring its flag.
            if let victim = others.first(where: { $0.requiredFlags.contains(flag) }) {
                return "Pressing this on its own fires before “\(victim.name)” can complete, so “\(victim.name)” may never trigger."
            }
        }
        if !candidate.requiredFlags.isEmpty {
            // Someone else is bare on a modifier this one needs.
            if let bully = others.first(where: {
                guard $0.isBareModifier, let f = $0.triggerFlag else { return false }
                return candidate.requiredFlags.contains(f)
            }) {
                return "“\(bully.name)” fires as soon as that modifier goes down, so this shortcut may never trigger."
            }
        }
        return nil
    }

    /// A well-known system shortcut this binding collides with. A warning, not
    /// a refusal — we cannot enumerate what the system actually holds.
    func systemWarning(for candidate: HotkeyBinding) -> String? {
        HotkeyBinding.systemShortcuts.first {
            $0.code == candidate.keyCode && $0.carbon == candidate.requiredCarbon
        }?.name
    }

    // MARK: Persistence

    private func persist() {
        syncPrimaryToSettings()
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data)
        else {
            migrateFromSettings()
            return
        }
        bindings = decoded
        migrateActivationToInherit()
    }

    /// One-time relaxation of a stored `activation` back to "inherit".
    ///
    /// `activation` used to be a required field, so every binding on disk
    /// carries whatever the live-dictation setting happened to be when it was
    /// created — and then never changed again. Toggling "Live dictation" did
    /// nothing to the shortcut people actually press, which is the bug this
    /// fixes.
    ///
    /// Only bindings that were never edited after they were created give up
    /// their stored value: an untouched binding never expressed a preference,
    /// while one the user opened and saved may well have. Runs once.
    private func migrateActivationToInherit() {
        let key = "hotkeyActivationInheritMigrated"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        var changed = false
        for i in bindings.indices where bindings[i].activation != nil
            && bindings[i].updatedAt == bindings[i].createdAt {
            bindings[i].activation = nil
            changed = true
        }
        if changed { persist() }
    }

    /// First launch after the update: turn the single stored hotkey into one
    /// binding named "Dictate", with every override left inheriting.
    ///
    /// The right-Option migration in `Settings.init` has already run by now and
    /// stays exactly where it is — this reads whatever it decided.
    private func migrateFromSettings() {
        let settings = Settings.shared
        // No `activation`: the binding follows the global Live dictation
        // switch, so flipping that switch keeps working forever after.
        bindings = [HotkeyBinding(
            name: "Dictate",
            keyCode: settings.hotkeyCode,
            carbonModifiers: settings.hotkeyModifiers
        )]
        UserDefaults.standard.set(true, forKey: "hotkeyActivationInheritMigrated")
        persist()
    }

    /// The FIRST binding is mirrored back into `Settings.hotkeyCode` /
    /// `hotkeyModifiers` on every write, so a downgraded build (which only
    /// knows about those two keys) still finds a working hotkey.
    private func syncPrimaryToSettings() {
        guard let first = bindings.first else { return }
        let settings = Settings.shared
        if settings.hotkeyCode != first.keyCode { settings.hotkeyCode = first.keyCode }
        if settings.hotkeyModifiers != first.carbonModifiers {
            settings.hotkeyModifiers = first.carbonModifiers
        }
    }
}
