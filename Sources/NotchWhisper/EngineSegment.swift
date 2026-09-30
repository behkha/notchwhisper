import Foundation

/// A span of recognized text and where it sits in the audio that produced it,
/// in seconds from the start of that audio. The engines other than WhisperKit
/// report timing in their own types; this is what they hand to `Transcriber`,
/// which turns it into whatever its callers need.
struct EngineSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String

    /// Groups word- or subword-timed tokens into sentence-sized segments — the
    /// unit meeting transcripts and file timestamps are shown in. A segment
    /// closes after sentence-ending punctuation, and before a new word that
    /// follows a pause — the same places Whisper would end one.
    ///
    /// A leading space marks the start of a word (SentencePiece tokens and
    /// Apple's word runs both arrive that way), so "3.5" (".", "5") never
    /// splits but "done. Next" does.
    static func group(_ tokens: [(text: String, start: Double, end: Double)],
                      pauseGap: Double = 0.6) -> [EngineSegment] {
        var out: [EngineSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var sentenceClosed = false
        var word = ""

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                out.append(EngineSegment(start: start, end: end, text: trimmed))
            }
            text = ""
            sentenceClosed = false
        }

        for token in tokens {
            let startsWord = token.text.hasPrefix(" ")
            if !text.isEmpty, startsWord, sentenceClosed || token.start - end >= pauseGap {
                flush()
            }
            if text.isEmpty { start = token.start }
            text += token.text
            end = max(end, token.end)
            word = startsWord ? token.text.trimmingCharacters(in: .whitespaces) : word + token.text
            if let last = token.text.trimmingCharacters(in: .whitespaces).last {
                // "Dr." ends a word, not a sentence.
                sentenceClosed = ".?!…。？！".contains(last)
                    && !abbreviations.contains(word.lowercased())
            }
        }
        flush()
        return out
    }

    private static let abbreviations: Set<String> = [
        "dr.", "mr.", "mrs.", "ms.", "prof.", "st.", "jr.", "sr.", "vs.", "e.g.", "i.e.",
    ]
}
