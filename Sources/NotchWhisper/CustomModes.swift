import Foundation
import SwiftUI

// MARK: - Modes
//
// A mode is a named instruction the user writes once ("Technical Writing: use
// precise technical language, never simplify product names…") and then picks
// before dictating — the instruction becomes the system prompt. There are no
// fixed built-in modes: the six that used to be hard-coded are installed as
// ordinary modes on first launch (see `seeds`) and can be edited or deleted.

/// How much latitude the model gets. Exposed in plain language because the
/// word "temperature" means nothing to someone writing a writing style.
enum ModeCreativity: String, Codable, CaseIterable, Identifiable {
    case precise
    case balanced
    case creative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .precise:  return "Precise"
        case .balanced: return "Balanced"
        case .creative: return "Creative"
        }
    }

    var blurb: String {
        switch self {
        case .precise:  return "Sticks closely to your words. Best for formatting, terminology and code."
        case .balanced: return "A little freedom in phrasing. Good default for most writing styles."
        case .creative: return "More rewriting freedom. Best for tone changes and drafting."
        }
    }

    var temperature: Double {
        switch self {
        case .precise:  return 0.1
        case .balanced: return 0.3
        case .creative: return 0.7
        }
    }
}

struct CustomMode: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var instructions: String
    var symbolName: String
    var creativity: ModeCreativity
    /// When true, a long transcript's per-chunk results are merged by a second
    /// pass instead of being concatenated — the right behaviour for modes that
    /// produce ONE document (a summary, a list) rather than transformed prose.
    var singleDocument: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String = "", instructions: String = "",
         symbolName: String = "sparkles", creativity: ModeCreativity = .balanced,
         singleDocument: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.symbolName = symbolName
        self.creativity = creativity
        self.singleDocument = singleDocument
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Seeded modes
    //
    // These six used to be hard-coded "built-in" modes. They are now ordinary
    // modes installed once, on first launch (or on the update that removed the
    // built-ins), so the user can read, edit, duplicate or delete them like
    // anything else. Their ids are fixed so a preference written before the
    // change — "builtin:cleanup", or the even older bare "cleanup" — still
    // resolves to the same mode.

    enum Seed {
        static let cleanUp    = UUID(uuidString: "A0000001-0000-4000-A000-000000000001")!
        static let markdown   = UUID(uuidString: "A0000001-0000-4000-A000-000000000002")!
        static let rewrite    = UUID(uuidString: "A0000001-0000-4000-A000-000000000003")!
        static let summarize  = UUID(uuidString: "A0000001-0000-4000-A000-000000000004")!
        static let structured = UUID(uuidString: "A0000001-0000-4000-A000-000000000005")!
        static let actions    = UUID(uuidString: "A0000001-0000-4000-A000-000000000006")!
        /// The old "Custom" mode's single ad-hoc instruction, if the user had
        /// written one. Only installed when there was something to keep.
        static let legacyCustom = UUID(uuidString: "A0000001-0000-4000-A000-000000000007")!
    }

    /// Maps a pre-modes stored value ("cleanup", "builtin:cleanup") onto the
    /// seeded mode that replaced it. "original" is not here: it became `.off`.
    static func legacySeedID(forRaw raw: String) -> UUID? {
        switch raw.hasPrefix("builtin:") ? String(raw.dropFirst(8)) : raw {
        case "cleanup":    return Seed.cleanUp
        case "markdown":   return Seed.markdown
        case "rewrite":    return Seed.rewrite
        case "summarize":  return Seed.summarize
        case "structured": return Seed.structured
        case "actions":    return Seed.actions
        case "custom":     return Seed.legacyCustom
        default:           return nil
        }
    }

    static func seed(id: UUID) -> CustomMode? { seeds.first { $0.id == id } }

    static let seeds: [CustomMode] = [
        CustomMode(id: Seed.cleanUp, name: "Clean Up",
                   instructions: """
                   Lightly clean up the transcript. My wording and personality must stay intact.
                   Remove filler words ("um", "uh", "you know", "like" used as filler, repeated false starts).
                   Fix punctuation, capitalization and obvious transcription mistakes.
                   Correct clear grammatical slips and merge unnecessarily fragmented sentences.
                   Remove accidental repetitions.
                   Do not restructure, reorder, add headings, or otherwise rewrite the content.
                   """,
                   symbolName: "wand.and.rays", creativity: .precise),
        CustomMode(id: Seed.markdown, name: "Markdown",
                   instructions: """
                   Format the transcript as clean Markdown without changing its meaning or wording. Organization and formatting only.
                   Infer structure from how it was spoken: headings, paragraphs, bullet and numbered lists, task lists and tables where the content fits them.
                   Format code, commands, file names and URLs with the right Markdown (fenced code blocks, inline code, links).
                   Use bold and italic sparingly, only where I emphasized something.
                   Do not paraphrase: keep my wording essentially unchanged.
                   """,
                   symbolName: "number", creativity: .precise),
        CustomMode(id: Seed.rewrite, name: "Rewrite",
                   instructions: """
                   Rewrite the transcript as polished written prose, preserving what I meant to say.
                   Fix grammar, remove filler and repetition, improve sentence structure and readability.
                   Turn spoken language into natural written language and organize fragmented thoughts.
                   Do not introduce new information.
                   """,
                   symbolName: "pencil.and.list.clipboard"),
        CustomMode(id: Seed.summarize, name: "Summarize",
                   instructions: """
                   Summarize the transcript.
                   Focus on the important information, decisions, numbers and names rather than shortening every sentence.
                   Use short paragraphs and bullets as appropriate.
                   """,
                   symbolName: "doc.plaintext", creativity: .creative, singleDocument: true),
        CustomMode(id: Seed.structured, name: "Structured Notes",
                   instructions: """
                   Turn the transcript into organized notes.
                   Choose a structure that fits the content (for example Topic, Key points, Decisions, Questions, Actions) rather than forcing every transcript into one template.
                   Use Markdown headings and lists. Keep all the important details.
                   """,
                   symbolName: "list.bullet.rectangle", creativity: .precise, singleDocument: true),
        CustomMode(id: Seed.actions, name: "Extract Actions",
                   instructions: """
                   Extract the actionable items from the transcript.
                   Produce a Markdown checklist of tasks, deadlines, follow-ups, decisions and important points.
                   Name the people mentioned when relevant. Only include items actually present in the transcript.
                   If there are no actionable items, reply with a single line saying so.
                   """,
                   symbolName: "checklist", creativity: .precise, singleDocument: true),
    ]

    /// Icons offered in the editor — enough to tell modes apart at a glance
    /// without turning into a symbol browser.
    static let iconChoices = [
        "sparkles", "text.alignleft", "chevron.left.forwardslash.chevron.right",
        "briefcase", "envelope", "bubble.left.and.bubble.right", "graduationcap",
        "megaphone", "list.bullet.clipboard", "globe", "heart.text.square",
        "theatermasks", "newspaper", "quote.opening", "flag", "star",
    ]

    /// Starting points offered on an empty Modes list. Nothing is installed
    /// behind the user's back — these only prefill the editor.
    static let templates: [CustomMode] = [
        CustomMode(name: "Technical Writing",
                   instructions: """
                   Use precise technical language.
                   Never simplify product names.
                   Preserve code identifiers, file paths and version numbers exactly.
                   Keep paragraphs short.
                   """,
                   symbolName: "chevron.left.forwardslash.chevron.right",
                   creativity: .precise),
        CustomMode(name: "Slack Message",
                   instructions: """
                   Rewrite as a short, friendly Slack message.
                   Lead with the point, then the detail.
                   Keep it under six lines and drop pleasantries.
                   """,
                   symbolName: "bubble.left.and.bubble.right"),
        CustomMode(name: "Email",
                   instructions: """
                   Rewrite as a professional email body.
                   Open with one line of context, then the ask, then next steps.
                   Polite but not flowery. No subject line, no signature.
                   """,
                   symbolName: "envelope"),
        CustomMode(name: "Meeting Minutes",
                   instructions: """
                   Turn the transcript into meeting minutes with the sections
                   Discussion, Decisions and Action items.
                   Attribute decisions and actions to the people named.
                   """,
                   symbolName: "list.bullet.clipboard",
                   creativity: .precise, singleDocument: true),
    ]
}

// MARK: - Selection

/// What the user picked in the mode picker: no processing at all, or one of
/// their modes. Persisted as a single string so adding kinds later doesn't
/// invalidate anyone's preferences.
enum ProcessingMode: Hashable, Identifiable {
    /// Insert the transcription as dictated — no AI, nothing leaves the Mac.
    case off
    case custom(UUID)

    var id: String { storageKey }

    /// What a fresh install starts on.
    static let initial = ProcessingMode.custom(CustomMode.Seed.cleanUp)

    /// Shown wherever a mode is named, so "off" reads the same everywhere.
    static let offLabel = "No processing"
    static let offSymbol = "text.justify"
    static let offBlurb = "Insert the transcription exactly as dictated. No AI, fully offline."

    var storageKey: String {
        switch self {
        case .off:            return "off"
        case .custom(let id): return "custom:\(id.uuidString)"
        }
    }

    init?(storageKey raw: String) {
        if raw == "off" || raw == "original" || raw == "builtin:original" {
            self = .off
        } else if raw.hasPrefix("custom:"), let id = UUID(uuidString: String(raw.dropFirst(7))) {
            self = .custom(id)
        } else if let id = CustomMode.legacySeedID(forRaw: raw) {
            // A preference written when the modes were built in.
            self = .custom(id)
        } else {
            return nil
        }
    }

    /// True when no LLM is involved at all.
    var isPassthrough: Bool {
        if case .off = self { return true }
        return false
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }
}

// MARK: - Resolved mode

/// Everything the runner needs to execute a mode. Resolving once keeps
/// `LLMRunner` free of mode-shape branches.
struct ResolvedMode {
    var displayName: String
    var symbolName: String
    var temperature: Double
    var reducesAcrossChunks: Bool
    var systemPrompt: String
    var reduceSystemPrompt: String
}

// MARK: - Store

@MainActor final class CustomModeStore: ObservableObject {
    static let shared = CustomModeStore()

    @Published private(set) var modes: [CustomMode] = []

    private let fileManager = FileManager.default
    private var url: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/custom-modes.json")
    }

    private init() { load() }

    func mode(id: UUID) -> CustomMode? { modes.first { $0.id == id } }

    func add(_ mode: CustomMode) {
        modes.append(mode)
        persist()
    }

    func update(_ mode: CustomMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var updated = mode
        updated.updatedAt = Date()
        modes[index] = updated
        persist()
    }

    func remove(_ mode: CustomMode) {
        modes.removeAll { $0.id == mode.id }
        persist()
    }

    /// A name that doesn't collide with an existing mode.
    func uniqueName(basedOn name: String) -> String {
        let taken = Set(modes.map { $0.name.lowercased() })
        var candidate = name
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func load() {
        if let data = try? Data(contentsOf: url) {
            modes = (try? JSONDecoder().decode([CustomMode].self, from: data)) ?? []
        }
        installSeedsOnce()
    }

    /// Installs the modes that used to be built in, exactly once. After that
    /// they are the user's: renaming, editing or deleting one sticks, because
    /// the flag — not the list — records that seeding happened.
    private func installSeedsOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        let existing = Set(modes.map { $0.id })
        var installed = CustomMode.seeds.filter { !existing.contains($0.id) } + modes
        // The old built-in "Custom" mode held one ad-hoc instruction. Keep it
        // as a real mode rather than dropping what the user wrote.
        let legacy = (defaults.string(forKey: "llmCustomPrompt") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty, !existing.contains(CustomMode.Seed.legacyCustom) {
            installed.append(CustomMode(id: CustomMode.Seed.legacyCustom,
                                        name: "My instruction",
                                        instructions: legacy,
                                        symbolName: "slider.horizontal.3"))
        }
        modes = installed
        defaults.set(true, forKey: Self.seededKey)
        persist()
    }

    private static let seededKey = "customModesSeeded"

    // MARK: Resolution

    /// Turns a selection into an executable mode. Returns nil for `.off` and
    /// for a mode that was deleted while still selected — the caller reports
    /// that rather than silently running something else.
    func resolve(_ selection: ProcessingMode) -> ResolvedMode? {
        guard let id = selection.customID, let mode = self.mode(id: id) else { return nil }
        return ResolvedMode(
            displayName: mode.name,
            symbolName: mode.symbolName,
            temperature: mode.creativity.temperature,
            reducesAcrossChunks: mode.singleDocument,
            systemPrompt: LLMPrompts.systemPrompt(forCustom: mode),
            reduceSystemPrompt: LLMPrompts.reduceSystemPrompt(forCustom: mode)
        )
    }

    /// Display label for a selection, including deleted-mode handling. Used by
    /// pickers and the menu bar.
    func label(for selection: ProcessingMode) -> String {
        switch selection {
        case .off:            return ProcessingMode.offLabel
        case .custom(let id): return self.mode(id: id)?.name ?? "Deleted mode"
        }
    }

    func symbol(for selection: ProcessingMode) -> String {
        switch selection {
        case .off:            return ProcessingMode.offSymbol
        case .custom(let id): return self.mode(id: id)?.symbolName ?? "questionmark"
        }
    }

    /// One line describing what the selection does — the mode's own
    /// instructions, flattened, or why nothing will run.
    func blurb(for selection: ProcessingMode) -> String {
        switch selection {
        case .off:
            return ProcessingMode.offBlurb
        case .custom(let id):
            guard let mode = self.mode(id: id) else { return "This mode was deleted. Pick another one." }
            let flat = mode.instructions
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
        }
    }
}
