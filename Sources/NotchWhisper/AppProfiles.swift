import Foundation
import SwiftUI

// MARK: - App profile
//
// One profile says "when I dictate into these apps, do this instead". Every
// field is an OPTIONAL override: nil means "use the global setting", so a
// profile that only changes the mode leaves everything else alone.
//
// Restrictions (never process, never store) will NOT follow this override
// model — see specs/00-FLAGS.md. Those are additive and cannot be relaxed by a
// more specific match. Keep the two kinds of merge apart.

struct AppProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Bundle identifiers this profile claims. One profile can cover several
    /// apps ("Code editors" = Xcode + VS Code + Zed).
    var bundleIDs: [String]
    /// Command-line programs this profile is for, inside those terminals —
    /// "claude", "codex", "vim". Empty (or nil, in an archive written before
    /// CLI targets existed) means the profile covers the terminal generally.
    /// A profile that names tools NEVER matches a non-terminal app.
    var cliTools: [String]?
    var symbolName: String
    var enabled: Bool

    /// Stored as the `ProcessingMode` storage key so an unknown or deleted
    /// selection degrades to "inherit" instead of failing the whole archive.
    var processingModeKey: String?
    var llmEnabled: Bool?
    /// Pin a specific LLM connection for these apps (e.g. the local one).
    var connectionID: UUID?
    var autoType: Bool?
    var insertNewline: Bool?
    /// Only applied before audio starts, never mid-recording.
    var modelId: String?
    /// How the text reaches the target. nil = decide automatically (paste into
    /// terminal PROGRAMS, type everywhere else).
    var insertionMode: AutoTyper.InsertionMode?

    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String = "", bundleIDs: [String] = [],
         cliTools: [String] = [],
         symbolName: String = "app.badge", enabled: Bool = true,
         processingMode: ProcessingMode? = nil, llmEnabled: Bool? = nil,
         connectionID: UUID? = nil, autoType: Bool? = nil,
         insertNewline: Bool? = nil, modelId: String? = nil,
         insertionMode: AutoTyper.InsertionMode? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.cliTools = cliTools.isEmpty ? nil : cliTools
        self.insertionMode = insertionMode
        self.symbolName = symbolName
        self.enabled = enabled
        self.processingModeKey = processingMode?.storageKey
        self.llmEnabled = llmEnabled
        self.connectionID = connectionID
        self.autoType = autoType
        self.insertNewline = insertNewline
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Non-optional view of `cliTools`.
    var tools: [String] {
        get { cliTools ?? [] }
        set { cliTools = newValue.isEmpty ? nil : newValue }
    }

    /// True when this profile targets a command-line program rather than the
    /// terminal window as a whole.
    var targetsCLI: Bool { !tools.isEmpty }

    func matches(tool: String?) -> Bool {
        guard targetsCLI else { return true }
        guard let tool else { return false }
        return tools.contains { $0.caseInsensitiveCompare(tool) == .orderedSame }
    }

    var processingMode: ProcessingMode? {
        get { processingModeKey.flatMap { ProcessingMode(storageKey: $0) } }
        set { processingModeKey = newValue?.storageKey }
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bundleIDs.isEmpty
    }

    /// How many settings this profile actually changes — drives the row summary.
    var overrideCount: Int {
        var n = 0
        if processingModeKey != nil { n += 1 }
        if insertionMode != nil { n += 1 }
        if llmEnabled != nil { n += 1 }
        if connectionID != nil { n += 1 }
        if autoType != nil { n += 1 }
        if insertNewline != nil { n += 1 }
        if modelId != nil { n += 1 }
        return n
    }

    static let iconChoices = [
        "app.badge", "bubble.left.and.bubble.right", "envelope", "terminal",
        "chevron.left.forwardslash.chevron.right", "note.text", "doc.richtext",
        "briefcase", "globe", "message", "calendar", "book", "hammer",
        "person.2", "square.grid.2x2", "star",
    ]

    /// Well-known apps offered as one-click starting points. These only prefill
    /// the editor — nothing is installed behind the user's back, the same rule
    /// `CustomMode.templates` follows.
    struct Suggestion: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var bundleIDs: [String]
        var cliTools: [String] = []
        var symbolName: String
    }

    static let suggestions: [Suggestion] = [
        .init(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
              symbolName: "bubble.left.and.bubble.right"),
        .init(name: "Mail", bundleIDs: ["com.apple.mail", "com.readdle.SparkDesktop", "com.superhuman.mail"],
              symbolName: "envelope"),
        .init(name: "Code editors",
              bundleIDs: ["com.apple.dt.Xcode", "com.microsoft.VSCode", "dev.zed.Zed", "com.jetbrains.intellij"],
              symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(name: "Notes", bundleIDs: ["com.apple.Notes", "md.obsidian", "notion.id"],
              symbolName: "note.text"),
        .init(name: "Terminal", bundleIDs: Array(AppContext.terminalBundleIDs).sorted(),
              symbolName: "terminal"),
        .init(name: "Claude Code", bundleIDs: Array(AppContext.terminalBundleIDs).sorted(),
              cliTools: ["claude"], symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(name: "Codex", bundleIDs: Array(AppContext.terminalBundleIDs).sorted(),
              cliTools: ["codex"], symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(name: "Messages", bundleIDs: ["com.apple.MobileSMS", "org.whispersystems.signal-desktop", "net.whatsapp.WhatsApp"],
              symbolName: "message"),
    ]
}

// MARK: - Effective settings

/// What the pipeline actually runs with, after an app profile has had its say.
/// Plain data: resolved once at recording start and carried through the
/// dictation, so nothing can change under a recording in flight.
struct EffectiveSettings {
    var processingMode: ProcessingMode
    var llmEnabled: Bool
    var connectionID: UUID?
    var autoType: Bool
    var insertNewline: Bool
    var modelId: String
    /// How the text is delivered. Resolved from the profile, or automatically
    /// from the destination when the profile says nothing.
    var insertionMode: AutoTyper.InsertionMode
    /// Whisper language code, or nil for auto-detect. Only a hotkey binding
    /// overrides this today; app profiles do not carry a language.
    var language: String?
    /// True when `modelId` came from a profile rather than from Settings —
    /// an explicit choice beats automatic model selection.
    var modelFromProfile: Bool
    /// The profile that produced this, or nil when global settings applied.
    var sourceProfile: AppProfile?
    /// The hotkey binding that produced this, or nil when the dictation was
    /// started from the Record button / menu bar.
    var sourceBinding: HotkeyBinding?
    /// The profile pins a connection that no longer exists. Processing is
    /// skipped rather than silently falling back to a different endpoint,
    /// which could be a hosted one.
    var pinnedConnectionMissing: Bool

    /// The connection this dictation should use, or nil when there is none.
    @MainActor var connection: LLMConnection? {
        if let connectionID {
            return LLMConnectionStore.shared.connection(id: connectionID)
        }
        return LLMConnectionStore.shared.active
    }

    /// Mirrors `Settings.llmActiveForCurrentMode`, profile-aware.
    @MainActor var llmActive: Bool {
        llmEnabled && !processingMode.isPassthrough && connection?.isUsable == true
    }

    var profileName: String? { sourceProfile?.name }
    var bindingName: String? { sourceBinding?.name }

    /// What the notch shows while this dictation runs: "Slack · Clean prose".
    /// nil when neither a profile nor a binding had anything to say.
    var sessionLabel: String? {
        let parts = [profileName, bindingName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Lays a hotkey binding's overrides on top of whatever the app profile
    /// decided. The BINDING wins: pressing a specific key is a more explicit
    /// statement of intent than "I happen to be in Slack".
    ///
    /// This is the *settings* merge — more specific overrides less specific.
    /// Privacy restrictions use the opposite (additive) merge; see
    /// specs/00-FLAGS.md §5.
    mutating func apply(_ binding: HotkeyBinding) {
        sourceBinding = binding
        if let mode = binding.processingMode { processingMode = mode }
        if let enabled = binding.llmEnabled { llmEnabled = enabled }
        if let autoType = binding.autoType { self.autoType = autoType }
        if let newline = binding.insertNewline { insertNewline = newline }
        if let language = binding.language {
            self.language = language.isEmpty ? nil : language
        }
        // A profile pinned a connection that no longer exists. That is a
        // refusal to send text somewhere unintended, not a preference, so a
        // binding asking for AI cannot lift it.
        if pinnedConnectionMissing { llmEnabled = false }
    }
}

// MARK: - Store

@MainActor final class AppProfileStore: ObservableObject {
    static let shared = AppProfileStore()

    @Published private(set) var profiles: [AppProfile] = []

    /// One-off escape hatch: the next dictation ignores app profiles entirely.
    /// Cleared as soon as it is used, so it can never become a sticky mode the
    /// user forgets about.
    @Published var bypassNextDictation = false

    private let fileManager = FileManager.default
    private var url: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/app-profiles.json")
    }

    private init() { load() }

    // MARK: Access

    func profile(id: UUID) -> AppProfile? { profiles.first { $0.id == id } }

    var enabledCount: Int { profiles.filter { $0.enabled && !$0.bundleIDs.isEmpty }.count }

    /// The profile claiming `bundleID`, if any. Exactly one profile may claim a
    /// given app — the editor enforces that, so first-match is unambiguous.
    func profileClaiming(_ bundleID: String, excluding id: UUID? = nil) -> AppProfile? {
        profiles.first { $0.id != id && $0.bundleIDs.contains(bundleID) }
    }

    /// The profile for a destination. A profile naming the CLI tool in front
    /// (Claude Code) beats one that only claims the terminal — the more
    /// specific statement of intent wins, the same rule the whole override
    /// model follows.
    func profile(for context: AppContext) -> AppProfile? {
        guard !context.isSelf, let bundleID = context.bundleID else { return nil }
        let claiming = profiles.filter { $0.enabled && $0.bundleIDs.contains(bundleID) }
        guard !claiming.isEmpty else { return nil }
        if let tool = context.cliTool,
           let specific = claiming.first(where: { $0.targetsCLI && $0.matches(tool: tool) }) {
            return specific
        }
        return claiming.first { !$0.targetsCLI }
    }

    // MARK: CRUD

    func add(_ profile: AppProfile) {
        profiles.append(profile)
        persist()
    }

    func update(_ profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.updatedAt = Date()
        profiles[index] = updated
        persist()
    }

    func remove(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].enabled = enabled
        profiles[index].updatedAt = Date()
        persist()
    }

    func uniqueName(basedOn name: String) -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        var candidate = name
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: Resolution

    /// Pure given the profile list: global settings, then the matching
    /// profile's non-nil overrides on top.
    func effective(for context: AppContext) -> EffectiveSettings {
        let settings = Settings.shared
        var result = EffectiveSettings(
            processingMode: settings.processingMode,
            llmEnabled: settings.llmEnabled,
            connectionID: nil,
            autoType: settings.autoTypeEnabled,
            insertNewline: settings.insertNewline,
            modelId: settings.modelId,
            insertionMode: defaultInsertionMode(for: context),
            language: settings.language,
            modelFromProfile: false,
            sourceProfile: nil,
            sourceBinding: nil,
            pinnedConnectionMissing: false
        )
        guard let profile = profile(for: context) else { return result }
        result.sourceProfile = profile

        if let mode = profile.processingMode { result.processingMode = mode }
        if let enabled = profile.llmEnabled { result.llmEnabled = enabled }
        if let pinned = profile.connectionID {
            if LLMConnectionStore.shared.connection(id: pinned) != nil {
                result.connectionID = pinned
            } else {
                // Never silently fall back — the pinned connection may have been
                // the local one, and the active one may not be.
                result.pinnedConnectionMissing = true
                result.llmEnabled = false
            }
        }
        if let autoType = profile.autoType { result.autoType = autoType }
        if let newline = profile.insertNewline { result.insertNewline = newline }
        if let mode = profile.insertionMode { result.insertionMode = mode }
        if let modelId = profile.modelId,
           ModelRegistry.shared.installedDescriptors.contains(where: { $0.id == modelId }) {
            result.modelId = modelId
            result.modelFromProfile = true
        }
        return result
    }

    /// Typing a newline into a terminal program SUBMITS the line, so a
    /// multi-line dictation into Claude Code or Codex arrives as several
    /// half-messages. Pasting keeps it as one block. Applied only to actual
    /// programs — at a bare shell prompt the text is a single command line,
    /// typing works, and there is no reason to borrow the user's clipboard.
    private func defaultInsertionMode(for context: AppContext) -> AutoTyper.InsertionMode {
        guard Settings.shared.pasteIntoTerminalTools else { return .keystrokes }
        guard context.isTerminal, context.cliTool != nil, !context.cliToolIsShell else {
            return .keystrokes
        }
        return .paste
    }

    /// Resolution for an actual dictation: honours (and consumes) a pending
    /// one-off bypass, then lets the hotkey binding that started it override
    /// whatever the profile decided.
    func resolveForDictation(context: AppContext,
                             binding: HotkeyBinding? = nil) -> EffectiveSettings {
        var result: EffectiveSettings
        if bypassNextDictation {
            bypassNextDictation = false
            result = effective(for: .empty)
        } else {
            result = effective(for: context)
        }
        if let binding { result.apply(binding) }
        return result
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        profiles = (try? JSONDecoder().decode([AppProfile].self, from: data)) ?? []
    }
}
