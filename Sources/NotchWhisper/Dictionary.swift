import Foundation
import SwiftUI

// MARK: - Dictionary
//
// A place to teach the model words it keeps getting wrong. Two entry types:
//   1. term    — a word/phrase the model should know (e.g. "Anthropic").
//   2. correction — when you hear X, write Y (e.g. "cloud code" → "Claude Code").
//
// Persistence: a JSON store (UserDefaults-backed file) AND a plain-text file
// the user can edit by hand. The text file is the source of truth on launch
// if it is newer; otherwise JSON wins. We keep both in sync.

enum DictEntryKind: String, Codable { case term, correction }

struct DictEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: DictEntryKind
    var phrase: String        // for .term: the word; for .correction: the heard form (X)
    var replacement: String   // for .correction: what to write (Y); empty for .term
    var note: String
    var createdAt: Date

    init(id: UUID = UUID(), kind: DictEntryKind, phrase: String, replacement: String = "", note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.phrase = phrase
        self.replacement = replacement
        self.note = note
        self.createdAt = createdAt
    }
}

/// A candidate warning surfaced in the UI when an entry looks like it would
/// clobber ordinary words.
struct DictWarning: Identifiable, Hashable {
    var id = UUID()
    var entryID: UUID
    var message: String
}

@MainActor final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published var entries: [DictEntry] = []
    @Published var search: String = ""
    @Published var warnings: [DictWarning] = []

    // File locations.
    private let fileManager = FileManager.default
    private var jsonURL: URL {
        appDir.appendingPathComponent("dictionary.json")
    }
    private var textURL: URL {
        appDir.appendingPathComponent("dictionary.txt")
    }
    private var appDir: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper")
    }

    // Common English words we must never corrupt with a correction.
    // (A correction for "Claude Code" must never touch "cloud" or "Cloudflare".)
    static let commonWords: Set<String> = {
        let s = """
        the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us
        cloud cloudflare apple google microsoft amazon meta openai anthropic vercel supabase code coding codes claude open close drive drives network nets works working said say
        """
        return Set(s.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() })
    }()

    private init() {
        load()
        rebuildWarnings()
    }

    // MARK: - CRUD
    func add(_ entry: DictEntry) {
        entries.append(entry)
        persist()
        rebuildWarnings()
    }

    func update(_ entry: DictEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        persist()
        rebuildWarnings()
    }

    func remove(_ entry: DictEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
        rebuildWarnings()
    }

    func filtered() -> [DictEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries.sorted { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending } }
        return entries.filter {
            $0.phrase.localizedCaseInsensitiveContains(q) ||
            $0.replacement.localizedCaseInsensitiveContains(q) ||
            $0.note.localizedCaseInsensitiveContains(q)
        }.sorted { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
    }

    // MARK: - Biasing context
    //
    // Pass the dictionary terms to the speech engine as context so it leans
    // toward producing them. Keep it SHORT — long context makes these models
    // drift and invent text on quiet audio. We send only the .term entries
    // (the things we want it to recognize) plus the correction TARGETS (Y),
    // capped to a small budget (≤ ~60 chars total of content).
    func biasingTerms() -> [String] {
        var out: [String] = []
        var budget = 60
        let terms = entries.filter { $0.kind == .term && !$0.phrase.isEmpty }
            .sorted { $0.phrase.count < $1.phrase.count } // shortest first = cheapest
        for t in terms {
            let cost = t.phrase.count + 1
            guard budget - cost >= 0 else { break }
            out.append(t.phrase)
            budget -= cost
        }
        // Also nudge toward correction targets so the right spelling appears.
        let targets = entries.filter { $0.kind == .correction && !$0.replacement.isEmpty }
            .map { $0.replacement }
        for y in targets {
            let cost = y.count + 1
            guard budget - cost >= 0 else { break }
            if !out.contains(y) { out.append(y); budget -= cost }
        }
        return out
    }

    // MARK: - Correction pass
    //
    // Guaranteed path: whole-word, case-insensitive, longest match first.
    // Handles words the model glues together (CloudCode, Cloud-Code) by
    // matching an optional separator (space or hyphen) between the parts.
    // A correction only fires on the FULL pattern and never on a substring
    // of a real word.
    func applyCorrections(_ text: String) -> (result: String, changes: [CorrectionChange]) {
        var changes: [CorrectionChange] = []
        var working = text

        // Build patterns from correction entries, longest phrase first.
        let corrections = entries.filter { $0.kind == .correction && !$0.phrase.isEmpty && !$0.replacement.isEmpty }
            .sorted { lhs, rhs in
                // Longest overall pattern (including separator flexibility) first.
                patternLength(lhs.phrase) > patternLength(rhs.phrase)
            }

        for c in corrections {
            let found = replaceAllMatches(in: working, pattern: c.phrase, replacement: c.replacement)
            if !found.matched.isEmpty {
                working = found.text
                changes.append(contentsOf: found.matched.map {
                    CorrectionChange(id: UUID(), heard: $0, wrote: c.replacement, entryID: c.id)
                })
            }
        }
        return (working, changes)
    }

    // Length used for ordering: count of alphanumeric chars in the phrase.
    private func patternLength(_ phrase: String) -> Int {
        phrase.filter { $0.isLetter || $0.isNumber }.count
    }

    /// Case-preserving whole-word replacement. The pattern's parts may be
    /// joined by an optional space or hyphen in the source text.
    private func replaceAllMatches(in text: String, pattern: String, replacement: String) -> (text: String, matched: [String]) {
        // Build a regex from the pattern: split on spaces, allow optional
        // [ -] between parts (space or hyphen, or nothing).
        let parts = pattern.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !parts.isEmpty else { return (text, []) }

        // Escape each part for regex, then join with an optional separator.
        let sep = "[ \\u00A0-]?"   // optional space (incl. non-breaking) or hyphen
        let joined = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: sep)

        // Whole-word boundaries: require the match to be delimited by start,
        // end, or a non-word char — and NOT preceded/followed by a letter that
        // would make it a substring of a larger real word.
        let regexStr = "(?i)(?<![a-z0-9])(?:\(joined))(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: regexStr, options: []) else {
            return (text, [])
        }

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return (text, []) }

        // Manual substitution: walk matches back-to-front so ranges stay valid,
        // inserting the replacement and capturing what was matched for the log.
        var matched: [String] = []
        var result = text
        for m in matches.reversed() {
            let matchedStr = ns.substring(with: m.range)
            matched.append(matchedStr)
            let r = Range(m.range, in: text)!
            result.replaceSubrange(r, with: replacement)
        }
        return (result, matched.reversed())
    }

    // MARK: - Warnings
    private func rebuildWarnings() {
        var w: [DictWarning] = []
        for e in entries where e.kind == .correction {
            // If any part of the heard phrase is a common word, warn — it may
            // clobber ordinary usage.
            let parts = e.phrase.lowercased().components(separatedBy: " ")
            for p in parts where Self.commonWords.contains(p) {
                w.append(DictWarning(entryID: e.id,
                    message: "“\(e.phrase)” contains the common word “\(p)” — the correction may fire on ordinary text."))
            }
            if e.replacement.lowercased().components(separatedBy: " ").contains(where: { Self.commonWords.contains($0) }) {
                // Less risky (replacement of a common word is fine), skip.
            }
            // Word-ending risk: pattern could match inside a longer word.
            if !e.phrase.isEmpty {
                let last = e.phrase.components(separatedBy: " ").last ?? ""
                if Self.commonWords.contains(last.lowercased()) {
                    w.append(DictWarning(entryID: e.id,
                        message: "“\(e.phrase)” ends in the common word “\(last)” — verify it won’t match real words."))
                }
            }
        }
        // De-dupe by message.
        var seen = Set<String>()
        warnings = w.filter { seen.insert($0.message).inserted }
    }

    // MARK: - Persistence
    private func load() {
        // Prefer whichever of the two files is newer.
        let jsonNewer = isNewer(jsonURL, than: textURL)
        if jsonNewer, let loaded = loadJSON() {
            entries = loaded
            writeTextFile() // keep text file in sync
            return
        }
        if let loaded = loadText() {
            entries = loaded
            writeJSON() // keep JSON in sync
            return
        }
        if let loaded = loadJSON() {
            entries = loaded
            return
        }
        entries = []
    }

    private func isNewer(_ a: URL, than b: URL) -> Bool {
        let aM = (try? fileManager.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
        let bM = (try? fileManager.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
        return aM > bM
    }

    func persist() {
        writeJSON()
        writeTextFile()
    }

    // JSON: structured, easy for the app.
    private func writeJSON() {
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: jsonURL)
        }
    }

    private func loadJSON() -> [DictEntry]? {
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        return try? JSONDecoder().decode([DictEntry].self, from: data)
    }

    // Plain text: editable by hand. Format (one entry per line):
    //   term: Anthropic
    //   term: Vercel
    //   fix: cloud code -> Claude Code
    //   # comments allowed, blank lines ignored.
    private func writeTextFile() {
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        var lines: [String] = []
        lines.append("# NotchWhisper dictionary — edit freely. Lines: \"term: <word>\" or \"fix: <heard> -> <write>\". Save to apply.")
        for e in entries {
            switch e.kind {
            case .term:
                lines.append("term: \(e.phrase)\(e.note.isEmpty ? "" : "  # \(e.note)")")
            case .correction:
                lines.append("fix: \(e.phrase) -> \(e.replacement)\(e.note.isEmpty ? "" : "  # \(e.note)")")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: textURL, atomically: true, encoding: .utf8)
    }

    private func loadText() -> [DictEntry]? {
        guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { return nil }
        var out: [DictEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            if l.hasPrefix("term:") {
                let phrase = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let (p, note) = splitNote(phrase)
                out.append(DictEntry(kind: .term, phrase: p, note: note))
            } else if l.hasPrefix("fix:") {
                let rest = l.dropFirst(4).trimmingCharacters(in: .whitespaces)
                // Split on " -> " or "=>".
                let parts = rest.components(separatedBy: " -> ").count > 1
                    ? rest.components(separatedBy: " -> ")
                    : rest.components(separatedBy: "=>")
                guard parts.count == 2 else { continue }
                let heard = parts[0].trimmingCharacters(in: .whitespaces)
                let (write, note) = splitNote(parts[1].trimmingCharacters(in: .whitespaces))
                out.append(DictEntry(kind: .correction, phrase: heard, replacement: write, note: note))
            }
        }
        return out.isEmpty ? nil : out
    }

    private func splitNote(_ s: String) -> (phrase: String, note: String) {
        if let hash = s.firstIndex(of: "#") {
            let phrase = String(s[..<hash]).trimmingCharacters(in: .whitespaces)
            let note = String(s[s.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            return (phrase, note)
        }
        return (s, "")
    }
}

/// One applied correction, recorded for the history audit log.
struct CorrectionChange: Identifiable, Codable, Hashable {
    var id: UUID
    var heard: String
    var wrote: String
    var entryID: UUID
}
