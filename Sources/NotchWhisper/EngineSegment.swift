import Foundation

/// A span of recognized text and where it sits in the audio that produced it,
/// in seconds from the start of that audio. The engines other than WhisperKit
/// report timing in their own types; this is what they hand to `Transcriber`,
/// which turns it into whatever its callers need.
struct EngineSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String

    /// Groups word- or subword-timed tokens into sentence-sized segments.
    ///
    /// Live dictation settles every segment except the last as soon as it
    /// appears, and skips a segment that ends inside audio it already typed, so
    /// segment boundaries decide both how early text is typed and how cleanly
    /// a re-read of the window's left edge is dropped. A segment closes after
    /// sentence-ending punctuation, and before a new word that follows a pause
    /// — the same places Whisper would end one.
    ///
    /// A leading space marks the start of a word (SentencePiece tokens and
    /// Apple's word runs both arrive that way), so "3.5" (".", "5") never
    /// splits but "done. Next" does.
    ///
    /// `splitAt` (seconds) is where the live loop's already-typed audio ends
    /// inside this window. The window's left edge re-hears that audio, often
    /// differently ("Tuesday" for "Thursday"), and a segment spanning both
    /// sides can only be de-duplicated by comparing text — which that
    /// difference defeats. Splitting there lets the loop drop the re-heard
    /// words by their timestamps instead.
    static func group(_ tokens: [(text: String, start: Double, end: Double)],
                      pauseGap: Double = 0.6,
                      splitAt: Double? = nil) -> [EngineSegment] {
        var out: [EngineSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var sentenceClosed = false
        var didSplit = splitAt == nil
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
            // A word starting just before the boundary (timings wobble between
            // passes) counts as after it.
            if !didSplit, startsWord, let boundary = splitAt, token.start >= boundary - 0.15 {
                flush()
                didSplit = true
            }
            if !text.isEmpty, startsWord, sentenceClosed || token.start - end >= pauseGap {
                flush()
            }
            if text.isEmpty { start = token.start }
            text += token.text
            end = max(end, token.end)
            word = startsWord ? token.text.trimmingCharacters(in: .whitespaces) : word + token.text
            if let last = token.text.trimmingCharacters(in: .whitespaces).last {
                // "Dr." ends a word, not a sentence: splitting there would let
                // live dictation commit "…met Dr." before the name arrives.
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
