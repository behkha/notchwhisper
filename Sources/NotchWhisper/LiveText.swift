import Foundation

/// One recognized word, placed in the live session's audio: `start` and `end`
/// are seconds from the moment the session started listening.
///
/// `text` keeps the engine's own spacing. In languages written with spaces a
/// word arrives with its leading space (" the"); Chinese and Japanese tokens
/// arrive with none. Text is rebuilt by concatenating words, so that spacing is
/// what reaches the page — `LiveText.join` only steps in where two decodes meet.
struct LiveWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Text rules for live dictation: joining the pieces different decodes return,
/// the few formatting touches applied before typing, and what may safely be
/// rewritten with Backspace.
enum LiveText {

    // MARK: - Joining

    /// `words` as one string, with the engine's spacing and none at the start.
    static func text<S: Sequence>(of words: S) -> String where S.Element == LiveWord {
        var out = ""
        for word in words { out = join(out, word.text) }
        return out
    }

    /// `right` written after `left`. Keeps `right`'s own leading space when it
    /// has one; otherwise adds a space only where the script uses them — a
    /// sentence from one decode must not be glued to the next ("lingers.It"),
    /// and Chinese must not gain spaces it never had.
    static func join(_ left: String, _ right: String) -> String {
        guard !right.isEmpty else { return left }
        guard let last = left.last else {
            return String(right.drop(while: { $0 == " " }))
        }
        if right.first == " " {
            // Never double a space the left side already ends with.
            return last == " " ? left + right.dropFirst() : left + right
        }
        guard let first = right.first else { return left }
        return needsSpace(between: last, and: first) ? left + " " + right : left + right
    }

    static func needsSpace(between a: Character, and b: Character) -> Bool {
        if a.isWhitespace || b.isWhitespace { return false }
        if attachesToPrevious.contains(b) { return false }
        if opensPhrase.contains(a) { return false }
        if isUnspacedScript(a) || isUnspacedScript(b) { return false }
        return true
    }

    /// Punctuation written against the word before it.
    private static let attachesToPrevious: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", ")", "]", "}", "%", "'", "’", "”", "»",
        "。", "，", "、", "！", "？", "；", "：",
    ]
    /// Punctuation written against the word after it.
    private static let opensPhrase: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡", "\"", "'"]

    /// Scripts written without spaces between words: CJK ideographs, kana,
    /// Thai, Lao, Khmer, Myanmar, and full-width punctuation. (Korean uses
    /// spaces, so Hangul is not here.)
    static func isUnspacedScript(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x0E00...0x0EFF,            // Thai, Lao
             0x1000...0x109F,            // Myanmar
             0x1780...0x17FF,            // Khmer
             0x3000...0x303F,            // CJK symbols and punctuation
             0x3040...0x30FF,            // Hiragana, Katakana
             0x31F0...0x31FF,            // Katakana phonetic extensions
             0x3400...0x4DBF,            // CJK extension A
             0x4E00...0x9FFF,            // CJK unified ideographs
             0xF900...0xFAFF,            // CJK compatibility ideographs
             0xFF00...0xFFEF,            // Half- and full-width forms
             0x20000...0x2FFFF:          // CJK extensions B+
            return true
        default:
            return false
        }
    }

    // MARK: - Formatting

    /// A phrase that starts a new sentence starts with a capital. Engines
    /// decoding a stretch that begins mid-thought often write it lower-case
    /// ("…budget. we agreed"); the text before it knows better.
    static func capitalizingAfterSentenceEnd(_ tail: String, typed: String) -> String {
        let endsSentence: Bool
        if let last = typed.last(where: { !$0.isWhitespace }) {
            endsSentence = ".?!".contains(last)
        } else {
            endsSentence = false
        }
        guard endsSentence,
              let index = tail.firstIndex(where: { !$0.isWhitespace }),
              tail[index].isLowercase else { return tail }
        return tail.replacingCharacters(in: index...index, with: tail[index].uppercased())
    }

    /// Whether Backspace over `c` removes exactly `c` in every app.
    ///
    /// A character built from several code points ("e" + combining accent, a
    /// Devanagari conjunct, a Persian letter followed by a zero-width
    /// non-joiner) is deleted one code point at a time by some text views and
    /// whole by others, so a rewrite counted in characters could eat a letter
    /// of the user's own text. Line breaks and tabs are out too: typed, they
    /// are Return and Tab — Return sends a chat message, Tab moves focus.
    static func isSafeToRewrite(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c != "\n" && c != "\r" && c != "\t"
    }

    /// The part of a tentative phrase that can go on the page before it is
    /// final: everything up to the word holding the first character that
    /// could not be taken back cleanly (see `isSafeToRewrite`).
    static func rewritablePrefix(_ text: String) -> String {
        guard let bad = text.firstIndex(where: { !isSafeToRewrite($0) }) else { return text }
        let head = text[..<bad]
        guard let space = head.lastIndex(of: " ") else { return "" }
        return String(text[..<space])
    }

    // MARK: - Comparing words

    /// A word reduced to what two decodes have to agree on: letters, digits and
    /// case-folded — Whisper moves punctuation around as a window grows.
    static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: wordEdgePunctuation.union(.whitespaces))
    }

    static let wordEdgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–-¿¡«»“”‘’")

    /// How many leading words two successive decodes of the same audio agree
    /// on — the "local agreement" that marks a stretch as settled. `exact`
    /// also requires the same punctuation and case: what the page may show.
    static func agreedPrefixCount(_ a: [LiveWord], _ b: [LiveWord], exact: Bool = false) -> Int {
        var n = 0
        while n < a.count, n < b.count,
              exact ? a[n].text.trimmingCharacters(in: .whitespaces) == b[n].text.trimmingCharacters(in: .whitespaces)
                    : key(a[n].text) == key(b[n].text) {
            n += 1
        }
        return n
    }

    // MARK: - Words already on the page

    /// Letters and digits only, case-folded — what two versions of the same
    /// words share whatever their punctuation, case or spacing, in any script.
    static func skeleton(_ text: String) -> [Character] {
        text.flatMap(fold)
    }

    private static func fold(_ c: Character) -> [Character] {
        String(c).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `text` without the words at its start that `covered` (a skeleton)
    /// already accounts for, and what is left of `covered` when `text` ends
    /// first — a live session skips the words the page already shows when
    /// they come back, final or guessed, after the user took over.
    ///
    /// Matching runs on letters and digits alone, so the typed version and
    /// the final version of the same words line up however their punctuation,
    /// case or spacing differ, in scripts without spaces too, and after a
    /// dictionary correction. A word respelled near the end ("odor" →
    /// "odour") still counts as covered; if the words part earlier, the end of
    /// `covered` is looked for a little further on; if it is nowhere near,
    /// `text` is not those words and nothing is dropped.
    static func dropCovered(_ covered: [Character], from text: String) -> (rest: String, left: [Character]) {
        guard !covered.isEmpty else { return (text, []) }
        let chars = Array(text)
        var matched = 0
        var index = 0
        /// Where the uncovered text starts, given the last covered character:
        /// after the rest of its word and its punctuation — in scripts written
        /// without spaces, a character is a word of its own.
        func uncovered(after i: Int) -> Int {
            var j = i + 1
            if isUnspacedScript(chars[i]) {
                while j < chars.count, !chars[j].isWhitespace, !(chars[j].isLetter || chars[j].isNumber) { j += 1 }
            } else {
                while j < chars.count, !chars[j].isWhitespace { j += 1 }
            }
            return j
        }
        while index < chars.count {
            for f in fold(chars[index]) {
                guard matched < covered.count else { break }
                if f == covered[matched] {
                    matched += 1
                    continue
                }
                if Double(matched) >= max(3, Double(covered.count) * 0.6) {
                    return (String(chars[uncovered(after: index)...]), [])
                }
                if let cut = realign(covered, in: chars) {
                    return (String(chars[uncovered(after: cut)...]), [])
                }
                return (text, [])
            }
            if matched >= covered.count {
                return (String(chars[uncovered(after: index)...]), [])
            }
            index += 1
        }
        return ("", Array(covered[matched...]))
    }

    /// Where the last few letters of `covered` turn up in `chars`, near where
    /// all of `covered` would end: the index of the character holding the
    /// last of them.
    private static func realign(_ covered: [Character], in chars: [Character]) -> Int? {
        let tail = Array(covered.suffix(min(8, covered.count)))
        guard tail.count >= 3 else { return nil }
        var skeleton: [Character] = []
        var owner: [Int] = []
        for (i, c) in chars.enumerated() {
            for f in fold(c) { skeleton.append(f); owner.append(i) }
        }
        let low = max(tail.count, Int(Double(covered.count) * 0.6))
        let high = min(skeleton.count, Int((Double(covered.count) * 1.4).rounded(.up)))
        guard low <= high else { return nil }
        for end in stride(from: high, through: low, by: -1) where Array(skeleton[(end - tail.count)..<end]) == tail {
            return owner[end - 1]
        }
        return nil
    }

    // MARK: - Decoder loops

    /// Longest repeated phrase `deloop` collapses. A Whisper decoder loop
    /// usually latches onto a whole short sentence, not a single word.
    static let maxLoopPhraseWords = 12

    /// Strips Whisper's decoder loop: on quiet or confusing audio it latches
    /// onto a phrase and emits it over and over ("CodeOpenAI CodeOpenAI …").
    /// A run of one short phrase is cut back to two occurrences, a longer one
    /// to one — genuine repetition ("no no", "very very") survives, and the
    /// thresholds keep ordinary speech from ever tripping it.
    static func deloop(_ words: [LiveWord]) -> [LiveWord] {
        var words = words
        guard words.count >= 2 else { return words }
        // Longest phrase first: a repeated nine-word sentence has to be caught
        // as a sentence, or the single-word pass shreds it first.
        for size in stride(from: maxLoopPhraseWords, through: 1, by: -1) {
            guard words.count >= size * 2 else { continue }
            let minRuns = size <= 3 ? 4 : 2
            let keep = size <= 3 ? 2 : 1
            let keys = words.map { key($0.text) }
            var out: [LiveWord] = []
            var i = 0
            while i < words.count {
                guard i + size * minRuns <= words.count else {
                    out.append(contentsOf: words[i...]); break
                }
                let phrase = keys[i..<(i + size)]
                var runs = 1
                var j = i + size
                while j + size <= words.count, keys[j..<(j + size)] == phrase {
                    runs += 1
                    j += size
                }
                if runs >= minRuns {
                    out.append(contentsOf: words[i..<(i + size * keep)])
                    i = j
                } else {
                    out.append(words[i])
                    i += 1
                }
            }
            words = out
        }
        return words
    }

    /// Drops Whisper's annotations for sounds that aren't speech —
    /// "[BLANK_AUDIO]", "(laughs)", "[Music playing]", "♪" — which are never
    /// something the user dictated. Only tags: a square-bracket span of a few
    /// words without digits (people don't dictate square brackets), or a
    /// parenthesised one naming a sound. Real parentheses stay — "(555)
    /// 123-4567", "(the Q3 ones)" — and a bracket that never closes drops
    /// nothing.
    static func removingAnnotations(_ words: [LiveWord]) -> [LiveWord] {
        var out: [LiveWord] = []
        var i = 0
        while i < words.count {
            let text = words[i].text.trimmingCharacters(in: .whitespaces)
            if let open = text.first, open == "[" || open == "(" {
                let close: Character = open == "[" ? "]" : ")"
                var end: Int?
                for j in i..<min(words.count, i + 4) {
                    let word = words[j].text.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
                    if word.last == close { end = j; break }
                }
                if let end {
                    let span = words[i...end].map(\.text).joined().lowercased()
                    let isTag = !span.contains(where: \.isNumber)
                        && (open == "[" || soundWords.contains { span.contains($0) })
                    if isTag { i = end + 1; continue }
                }
            }
            if !text.isEmpty, text.allSatisfy({ "♪♫♬♩".contains($0) }) { i += 1; continue }
            out.append(words[i])
            i += 1
        }
        return out
    }

    /// What Whisper puts in parentheses when it hears something other than
    /// speech.
    private static let soundWords = [
        "music", "laugh", "chuckl", "applause", "cough", "sigh", "silence", "inaudible",
        "crosstalk", "noise", "beep", "breath", "sniff", "static", "typing", "clicking",
        "gasp", "groan", "sneez", "clears throat", "blank_audio", "no speech", "mumbl",
    ]
}

// MARK: - Self-test

/// `--live-text-selftest`: the text rules live dictation depends on, with no
/// model and no microphone. Exits 0 when every check holds.
enum LiveTextSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ got: String, _ expected: String) {
            let ok = got == expected
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  (got \"\(got)\", expected \"\(expected)\")")")
            if !ok { failures += 1 }
        }
        func words(_ list: [String]) -> [LiveWord] {
            list.enumerated().map { LiveWord(text: $1, start: Double($0), end: Double($0) + 0.5) }
        }
        func skip(_ typed: String, _ text: String) -> String {
            let out = LiveText.dropCovered(LiveText.skeleton(typed), from: text)
            return out.left.isEmpty ? out.rest.trimmingCharacters(in: .whitespaces) : "…left \(String(out.left))"
        }

        check("join adds a space between sentences", LiveText.join("lingers.", "It takes"), "lingers. It takes")
        check("join keeps Chinese unspaced", LiveText.join("你好", "世界"), "你好世界")
        check("join attaches punctuation", LiveText.join("odor", "."), "odor.")
        check("join keeps the right side's own space", LiveText.join("odor.", " A cold"), "odor. A cold")

        check("skip exact words", skip("It takes heat", "It takes heat to bring"), "to bring")
        check("skip ignores punctuation and case", skip("the odor", "The odor. A cold dip"), "A cold dip")
        check("skip a respelled last word", skip("bring out the odor", "bring out the odour. A cold"), "A cold")
        check("skip Chinese without spaces", skip("你好", "你好世界"), "世界")
        check("skip Chinese with its punctuation", skip("你好", "你好，世界"), "世界")
        check("skip across a dictionary correction", skip("NotchWhisper is", "NotchWhisper is great"), "great")
        check("skip after a merged word", skip("to day we", "today we ship"), "ship")
        check("skip leaves a shorter batch pending", skip("It takes heat to bring", "It takes"), "…left heattobring")
        check("skip drops nothing from unrelated text", skip("completely different", "A cold dip"), "A cold dip")

        let tagged = LiveText.text(of: LiveText.removingAnnotations(
            words([" Hello", " [BLANK_AUDIO]", " world", " (laughs)", " again"])))
        check("annotations removed", tagged, "Hello world again")
        let phone = LiveText.text(of: LiveText.removingAnnotations(words([" Call", " (555)", " 123-4567."])))
        check("a phone number's parentheses stay", phone, "Call (555) 123-4567.")
        let aside = LiveText.text(of: LiveText.removingAnnotations(
            words([" Use", " (the", " Q3", " ones),", " then", " ship."])))
        check("a real parenthetical stays", aside, "Use (the Q3 ones), then ship.")
        let open = LiveText.text(of: LiveText.removingAnnotations(words([" A", " (note", " that", " never", " closes", " ends"])))
        check("an unclosed bracket drops nothing", open, "A (note that never closes ends")

        let looped = LiveText.text(of: LiveText.deloop(words(Array(repeating: " again", count: 6))))
        check("a word loop is cut back", looped, "again again")
        check("a stop after a sentence gets a capital", LiveText.capitalizingAfterSentenceEnd("we agreed", typed: "budget."), "We agreed")
        check("rewritable prefix stops before a combined character",
              LiveText.rewritablePrefix("namaste नमस्ते friend"), "namaste")

        print(failures == 0 ? "live-text-selftest: all checks passed" : "live-text-selftest: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
