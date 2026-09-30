import Foundation

/// A live-dictation recognizer. Audio goes in as it is captured; text comes
/// out in two tiers, the way live captions work:
///
///  · `finalWords` never change once published. They are typed and stay typed.
///  · `volatileWords` are the current best guess at the speech after them,
///    replaced wholesale on every update. They are shown at once — and typed,
///    when rewriting is on — and corrected as more of the sentence is heard.
///
/// Word times are seconds from the start of the session.
@MainActor
protocol LiveRecognizer: AnyObject {
    var finalWords: [LiveWord] { get }
    var volatileWords: [LiveWord] { get }
    /// The part of the guess worth typing into the document: words that have
    /// held still. The caption shows `volatileWords`; the page gets these, so
    /// a guess the next pass takes back never reaches it.
    var settledWords: [LiveWord] { get }
    /// Called on the main actor after either tier changed.
    var onUpdate: (() -> Void)? { get set }
    /// How often the session should call `process()`.
    var tickSeconds: Double { get }
    /// Mean cost of a decode pass, for engines that re-decode (the
    /// too-slow-model notice); nil for engines that stream natively.
    var meanDecodeSeconds: Double? { get }

    func start() async throws
    /// 16 kHz mono, contiguous with everything appended before.
    func append(_ samples: [Float])
    /// The recognizer's periodic work — a decode, for engines that re-decode.
    func process() async
    /// One last pass over whatever is still volatile. Afterwards
    /// `volatileWords` is empty and `finalWords` holds the whole session.
    func finish() async
    func cancel()
}

/// Live dictation for engines that decode whole clips — Whisper and Parakeet.
///
/// Each pass re-decodes the WHOLE unfinished phrase, from where the final text
/// ends up to the live edge, rather than a short window stitched onto the
/// last one. The model always sees the phrase from its start, so each pass
/// is as accurate as a hold-to-talk transcription of the same words, and an
/// early guess is corrected by the next pass instead of being typed forever.
/// (Stitching two-second windows was what dropped and duplicated words at the
/// seams: "A cold dip. Health and zest.")
///
/// Text becomes final:
///  · at a pause — `endpointSilenceSeconds` of quiet after speech — with one
///    last decode of exactly the spoken audio. The next phrase starts clean.
///  · a sentence at a time, once two consecutive passes agree on it and
///    speech has gone on past it, cut in the pause after its full stop;
///  · when a phrase runs on for `softCutSeconds`, at its best agreed boundary
///    (a clause mark with a dip in the audio, or a real pause);
///  · at `maxOpenSeconds`, at the best boundary whether settled or not, so
///    the decode window stays inside what the model handles in one pass.
/// Cuts go where the audio is quietest between two words (see `bestCut`).
///
/// The page is fed only words two passes wrote identically (see `publish`);
/// the caption shows every guess.
///
/// Silence is never decoded: Whisper invents "Thank you." on it.
@MainActor
final class RedecodeLiveRecognizer: LiveRecognizer {
    struct Tuning {
        var tickSeconds: Double
        /// New audio needed before another pass is worth its cost.
        var minNewAudioSeconds: Double
        /// Quiet after speech that ends a phrase.
        var endpointSilenceSeconds: Double
        var softCutSeconds: Double
        var maxOpenSeconds: Double
        /// Windows shorter than this are padded with silence at the end.
        var minWindowSeconds: Double
        /// Whisper-only cleanups: sound annotations, "Thank you." on noise.
        var isWhisper: Bool

        static let whisper = Tuning(
            tickSeconds: 0.15, minNewAudioSeconds: 0.3, endpointSilenceSeconds: 0.6,
            softCutSeconds: 8, maxOpenSeconds: 20, minWindowSeconds: 1.2,
            isWhisper: true)
        /// Parakeet returns nothing for a clip under about 2.1 s, however much
        /// speech is in it; padded with silence to 2.4 s, a 1.2 s phrase start
        /// decodes fine (measured on FluidAudio 0.17.4).
        static let parakeet = Tuning(
            tickSeconds: 0.12, minNewAudioSeconds: 0.2, endpointSilenceSeconds: 0.6,
            softCutSeconds: 8, maxOpenSeconds: 13, minWindowSeconds: 2.4,
            isWhisper: false)
    }

    /// Decodes a window. Times in the result are seconds from its start.
    typealias Decode = @MainActor (_ samples: [Float]) async throws -> [LiveWord]

    private let decode: Decode
    private let tuning: Tuning
    private var voice: LiveVoiceTracker
    private let sensitivity: VoiceActivityDetector.Sensitivity
    private let rate = Double(LiveVoiceTracker.sampleRate)

    /// Captured audio from `audioStart` (an absolute sample index) on.
    private var audio: [Float] = []
    private var audioStart = 0
    private var edge: Int { audioStart + audio.count }
    /// Start of the phrase that is not final yet (absolute sample index).
    private var openStart = 0
    /// The window the last pass decoded, so an unchanged one is not re-run.
    private var lastWindow: (from: Int, to: Int)?
    /// The previous pass's words for the open phrase (local agreement).
    private var previousHypothesis: [LiveWord] = []
    private var decodeCosts: [Double] = []
    /// After a cut inside a sentence: the first word after the cut, written as
    /// the model wrote it while it could still hear the sentence's start. The
    /// next window starts on that word and the model capitalizes it as if a
    /// sentence began ("if anything slips, Tell me"); this puts its case back.
    private var continuation: LiveWord?

    private(set) var finalWords: [LiveWord] = []
    private(set) var volatileWords: [LiveWord] = []
    private(set) var settledWords: [LiveWord] = []
    var onUpdate: (() -> Void)?
    /// Prints every pass (the self-test's --verbose).
    static var debugLog = false

    var tickSeconds: Double { tuning.tickSeconds }
    var meanDecodeSeconds: Double? {
        decodeCosts.count >= 3 ? decodeCosts.reduce(0, +) / Double(decodeCosts.count) : nil
    }

    init(tuning: Tuning, sensitivity: VoiceActivityDetector.Sensitivity, decode: @escaping Decode) {
        self.tuning = tuning
        self.decode = decode
        self.sensitivity = sensitivity
        self.voice = LiveVoiceTracker(sensitivity: sensitivity)
    }

    func start() async throws {}

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        audio.append(contentsOf: samples)
        voice.append(samples)
    }

    func cancel() {}

    // MARK: - Passes

    func process() async {
        let edge = self.edge
        guard voice.hasSpeech(from: openStart, to: edge) else {
            // Nothing said since the last final word. Keep a little lead-in
            // (Whisper mishears a word that starts on the window's first
            // sample) and let the rest go; drop a guess made on a blip that
            // turned out not to be speech.
            if !voice.isSpeaking {
                openStart = max(openStart, edge - Int(0.4 * rate))
                trimAudio()
            }
            if !volatileWords.isEmpty || !settledWords.isEmpty {
                volatileWords = []
                settledWords = []
                previousHypothesis = []
                onUpdate?()
            }
            return
        }

        // The speaker paused: the phrase is over. One decode of exactly the
        // spoken audio plus some of the quiet after it (the model needs to hear
        // the pause to end the sentence), and all of it becomes final.
        if let lastSpeech = voice.lastSpeechEnd, !voice.isSpeaking,
           Double(edge - lastSpeech) >= tuning.endpointSilenceSeconds * rate {
            await finalizeOpenPhrase(through: min(edge, lastSpeech + Int(trailingQuietSeconds * rate)))
            return
        }

        guard Double(edge - (lastWindow?.to ?? 0)) >= tuning.minNewAudioSeconds * rate
                || lastWindow?.from != openStart else { return }
        // A first guess on a syllable is noise that the next pass takes back.
        guard let speechStart = voice.firstSpeechStart(from: openStart),
              Double(edge - speechStart) >= 0.35 * rate else { return }
        var end = edge
        if !voice.isSpeaking, let lastSpeech = voice.lastSpeechEnd,
           edge - lastSpeech > Int(trailingQuietSeconds * rate) {
            end = lastSpeech + Int(trailingQuietSeconds * rate)   // more quiet adds only risk
        }
        if let last = lastWindow, last.from == openStart, last.to == end { return }

        let started = Date()
        guard let words = await decodeWindow(from: openStart, to: end) else { return }
        decodeCosts.append(Date().timeIntervalSince(started))
        if decodeCosts.count > 20 { decodeCosts.removeFirst() }
        lastWindow = (openStart, end)
        // Speech went in and nothing came out: a decoder hiccup (Parakeet has
        // them on some window lengths), not silence. Keep the last guess.
        guard !words.isEmpty else {
            log("empty pass over \(seconds(openStart))–\(seconds(end)) — keeping the last guess")
            return
        }

        let cost = Date().timeIntervalSince(started)
        var agreed = LiveText.agreedPrefixCount(previousHypothesis, words)
        var open = words
        let openSeconds = Double(edge - openStart) / rate
        let edgeTime = Double(edge) / rate
        var cutNote = ""
        // A sentence two passes agree on, with speech already after it, is
        // done: make it final so later passes cannot rewrite it (Parakeet flips
        // "odor"/"odour" as its window grows). A phrase that runs on is cut at
        // its best settled boundary, and at the cap at its best boundary.
        if let cut = bestCut(in: words, within: agreed, endingBy: edgeTime - 0.8, minimumScore: 4)
            ?? (openSeconds >= tuning.softCutSeconds
                ? bestCut(in: words, within: agreed, endingBy: edgeTime - 1.0, minimumScore: 2) : nil) {
            cutNote = " · final through “\(LiveText.text(of: words[..<cut.index]).suffix(24))”"
            open = commitPrefix(of: words, cut: cut)
            agreed -= cut.index
        } else if openSeconds >= tuning.maxOpenSeconds,
                  let cut = bestCut(in: words, within: words.count, endingBy: edgeTime - 0.5, minimumScore: 0) {
            cutNote = " · capped at “\(LiveText.text(of: words[..<cut.index]).suffix(24))”"
            open = commitPrefix(of: words, cut: cut)
            agreed = 0
        } else if openSeconds >= tuning.softCutSeconds, !Self.hasWordTimings(words),
                  let gap = quietGap(minimumSeconds: openSeconds >= tuning.maxOpenSeconds ? 0.08 : 0.3) {
            // Words without their own timings (a Whisper segment the aligner
            // skipped) give no boundary to cut at: end the final stretch in a
            // pause the voice detector heard, with a decode of exactly that
            // stretch. Keeps the window — and the pass cost — bounded.
            log("pass \(seconds(openStart))–\(seconds(end)) \(Int(cost * 1000)) ms: \(LiveText.text(of: words))"
                + " · final through the pause at \(seconds(gap))")
            previousHypothesis = words
            await finalizeOpenPhrase(through: gap, keepingRestOf: words)
            return
        }
        log("pass \(seconds(openStart))–\(seconds(end)) \(Int(cost * 1000)) ms"
            + " agreed \(max(0, agreed))/\(open.count): \(LiveText.text(of: open))\(cutNote)")
        // The page takes words once two passes wrote them identically —
        // punctuation included, so a comma the model adds as it hears more is
        // typed when it holds, near the end of the page, instead of all of a
        // sentence's commas arriving at once with its final text.
        var typed = LiveText.agreedPrefixCount(previousHypothesis, open, exact: true)
        // Slow passes: waiting for a second one to agree would double how far
        // the page trails the voice. Type all but the word still being spoken.
        if cost > 0.35 { typed = max(typed, open.count - 1) }
        previousHypothesis = open
        publish(open, agreed: typed)
    }

    /// Whether the words carry their own times — rather than all sharing one
    /// segment's span — so a cut can be placed between two of them.
    private static func hasWordTimings(_ words: [LiveWord]) -> Bool {
        zip(words, words.dropFirst()).contains { $1.start > $0.start && $1.start >= $0.end - 0.01 }
    }

    /// The quietest point of the longest pause of at least `minimumSeconds`
    /// the voice detector heard inside the open phrase, well clear of both
    /// ends. The longest, not the latest: the pause between two sentences is
    /// longer than one between words, and a cut inside a sentence costs the
    /// decoder the rest of it — Whisper then invents the next word ("the new
    /// onboarding flow should ships").
    private func quietGap(minimumSeconds: Double) -> Int? {
        let gaps = voice.gaps(from: openStart + Int(1.5 * rate), to: edge - Int(1.0 * rate),
                              minLength: Int(minimumSeconds * rate))
        guard let gap = gaps.max(by: { $0.end - $0.start < $1.end - $1.start }) else { return nil }
        return quietestFrame(from: gap.start, to: gap.end).sample
    }

    /// Quiet kept after the last word when a window ends in a pause.
    private let trailingQuietSeconds = 0.5

    /// Publishes a pass. The caption gets the whole guess; the page gets the
    /// words two passes agreed on — and keeps what it already shows until two
    /// passes agree on something DIFFERENT. One pass disagreeing with the last
    /// says only that the model is unsure, and taking the words back for it
    /// deleted and retyped whole sentences (measured: 55% of what Parakeet
    /// typed on a monologue).
    ///
    /// The engines end every window with a full stop, as if the speaker had
    /// finished, and the next pass takes it back when they had not. The page's
    /// last word goes without it; the real one arrives with the final text.
    private func publish(_ words: [LiveWord], agreed: Int) {
        let candidate = Array(words.prefix(agreed))
        var page = settledWords
        var same = 0
        while same < page.count, same < candidate.count {
            let shown = page[same].text.trimmingCharacters(in: .whitespaces)
            let heard = candidate[same].text.trimmingCharacters(in: .whitespaces)
            if shown == heard {
                page[same].start = candidate[same].start
                page[same].end = candidate[same].end
            } else if same == page.count - 1, shown == Self.withoutFullStop(heard) {
                // The page's last word, typed without its full stop: take the
                // stop back now — on the page that is an append, not a retype.
                page[same] = candidate[same]
            } else {
                break
            }
            same += 1
        }
        if same < candidate.count {
            // Longer (new words), or a confirmed change from `same` on.
            page = Array(page.prefix(same)) + candidate[same...]
        }
        if let last = page.last {
            let text = Self.withoutFullStop(last.text)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { page[page.count - 1].text = text }
        }
        let changed = words != volatileWords || page != settledWords
        volatileWords = words
        settledWords = page
        if changed { onUpdate?() }
    }

    private static func withoutFullStop(_ word: String) -> String {
        var text = word
        while let mark = text.last, ".?!。？！".contains(mark) { text.removeLast() }
        return text
    }

    private func seconds(_ sample: Int) -> String { String(format: "%.2f", Double(sample) / rate) }

    private func log(_ message: @autoclosure () -> String) {
        guard Self.debugLog else { return }
        fputs("NotchWhisper[live]: \(message())\n", stderr)
    }

    func finish() async {
        let edge = self.edge
        if voice.hasSpeech(from: openStart, to: edge) || voice.isSpeaking {
            var end = edge
            if !voice.isSpeaking, let lastSpeech = voice.lastSpeechEnd,
               edge - lastSpeech > Int(trailingQuietSeconds * rate) {
                end = max(openStart, lastSpeech + Int(trailingQuietSeconds * rate))
            }
            await finalizeOpenPhrase(through: end)
        } else if !volatileWords.isEmpty || !settledWords.isEmpty {
            volatileWords = []
            settledWords = []
            onUpdate?()
        }
    }

    // MARK: - Finalizing

    /// Decodes the open phrase up to `end` one last time and makes all of it
    /// final. `keepingRestOf` is the last guess at the phrase when the cut is
    /// mid-speech: its words past the ones just made final stay up as the new
    /// guess until the next pass replaces it, so the page does not delete and
    /// retype them in between.
    private func finalizeOpenPhrase(through end: Int, keepingRestOf guess: [LiveWord] = []) async {
        let from = openStart
        var committed = 0
        if end > from {
            let decoded = await decodeWindow(from: from, to: end)
            // Stopped mid-decode: leave the phrase open for `finish()`.
            if Task.isCancelled { return }
            if let words = decoded, !words.isEmpty {
                if isLikelyHallucination(words, from: from, to: end) {
                    log("dropped \"\(LiveText.text(of: words))\" — Whisper's stock phrase on marginal audio")
                } else {
                    finalWords.append(contentsOf: words)
                    committed = words.count
                    log("final \(seconds(from))–\(seconds(end)): \(LiveText.text(of: words))")
                }
            } else if !guess.isEmpty {
                // A cut inside speech can wait for the next pass.
                log("final pass over \(seconds(from))–\(seconds(end)) gave nothing — phrase stays open")
                return
            } else {
                // The phrase ended and the decode failed or came back empty.
                // The last guess is better than nothing.
                finalWords.append(contentsOf: previousHypothesis)
                committed = previousHypothesis.count
                log("final pass over \(seconds(from))–\(seconds(end)) gave nothing — kept the last guess")
            }
        }
        openStart = max(openStart, end)
        lastWindow = nil
        trimAudio()
        continuation = guess.count > committed ? guess[committed] : nil
        if guess.count > committed {
            let clamp = { (w: LiveWord) in
                LiveWord(text: w.text, start: max(w.start, Double(end) / self.rate), end: max(w.end, Double(end) / self.rate))
            }
            previousHypothesis = guess.dropFirst(committed).map(clamp)
            volatileWords = previousHypothesis
            settledWords = settledWords.dropFirst(committed).map(clamp)
            onUpdate?()
        } else {
            volatileWords = []
            settledWords = []
            previousHypothesis = []
            onUpdate?()
        }
    }

    /// Whisper's stock phrases for noise ("Thank you.", "you") — dropped only
    /// when the audio behind them was marginal, since people do say thanks.
    private func isLikelyHallucination(_ words: [LiveWord], from: Int, to: Int) -> Bool {
        guard tuning.isWhisper, !words.isEmpty else { return false }
        let lo = max(0, from - audioStart), hi = min(audio.count, to - audioStart)
        guard hi > lo else { return false }
        let analysis = VoiceActivityDetector(sensitivity: sensitivity).analyse(Array(audio[lo..<hi]))
        return VoiceActivityDetector.isLikelyHallucination(LiveText.text(of: words), analysis: analysis)
    }

    private struct Cut { let index: Int; let sample: Int }

    /// Makes `words[..<cut.index]` final and returns the rest, which stays open.
    private func commitPrefix(of words: [LiveWord], cut: Cut) -> [LiveWord] {
        finalWords.append(contentsOf: words[..<cut.index])
        continuation = words[cut.index]
        settledWords = Array(settledWords.dropFirst(cut.index))
        openStart = max(openStart, cut.sample)
        lastWindow = nil
        trimAudio()
        return Array(words[cut.index...])
    }

    /// Where to end the final part of the open phrase: after one of its first
    /// `within` words, ending no later than `endingBy` seconds.
    ///
    /// Each boundary is scored by what the text says — a sentence end (3), a
    /// clause mark (1) — and by what the audio says: how quiet the quietest
    /// 10 ms between the two words is against the phrase's speech (2 for a real
    /// pause, 1 for a dip). The cut goes at that quietest point. Word times
    /// alone are not precise enough: cut halfway between them and the knife
    /// can land in the tail of a word ("next week. Week, on Monday") or in an
    /// unvoiced onset the voice detector never counted ("…nine thirty to").
    private func bestCut(in words: [LiveWord], within: Int, endingBy: Double, minimumScore: Double) -> Cut? {
        let limit = min(within, words.count - 1)   // the last word always stays open
        guard limit >= 1 else { return nil }
        let loud = typicalFrameEnergy()
        var best: (index: Int, score: Double, sample: Int)?
        for i in 1...limit {
            let previous = words[i - 1], next = words[i]
            guard previous.end <= endingBy else { break }
            // Words that share one span cannot be told apart in time.
            guard next.start >= previous.end - 0.01 else { continue }
            let quiet = quietestFrame(from: Int((previous.end - 0.08) * rate), to: Int((next.start + 0.08) * rate))
            let depth = quiet.energy / max(loud, 1e-12)
            var score = depth < 0.03 ? 2.0 : depth < 0.12 ? 1.0 : 0.0
            if let mark = previous.text.trimmingCharacters(in: .whitespaces).last {
                if ".?!。？！".contains(mark) { score += 3 } else if ",;:，、".contains(mark) { score += 1 }
            }
            score += Double(i) * 0.01               // later, so more becomes final
            if score >= minimumScore, best == nil || score > best!.score { best = (i, score, quiet.sample) }
        }
        guard let best else { return nil }
        return Cut(index: best.index, sample: min(edge, max(openStart, best.sample)))
    }

    /// The quietest 10 ms frame in `from ..< to` (clamped to the open audio):
    /// its middle sample and its mean-square energy.
    private func quietestFrame(from: Int, to: Int) -> (sample: Int, energy: Float) {
        let frame = 160
        let lo = max(audioStart, openStart, from), hi = min(edge, to)
        guard hi - lo >= frame else { return ((lo + hi) / 2, 0) }
        var best = (sample: (lo + hi) / 2, energy: Float.greatestFiniteMagnitude)
        var position = lo
        while position + frame <= hi {
            let energy = frameEnergy(at: position, length: frame)
            if energy < best.energy { best = (position + frame / 2, energy) }
            position += frame
        }
        return best
    }

    /// Speech loudness of the open phrase: the 60th percentile of its 10 ms
    /// frame energies (most of an open phrase is speech).
    private func typicalFrameEnergy() -> Float {
        let frame = 160
        var energies: [Float] = []
        var position = max(audioStart, openStart)
        while position + frame <= edge {
            energies.append(frameEnergy(at: position, length: frame))
            position += frame
        }
        guard !energies.isEmpty else { return 0 }
        energies.sort()
        return energies[energies.count * 6 / 10]
    }

    private func frameEnergy(at position: Int, length: Int) -> Float {
        var sum: Float = 0
        for i in (position - audioStart)..<(position - audioStart + length) { sum += audio[i] * audio[i] }
        return sum / Float(length)
    }

    // MARK: - Decoding

    /// Decodes `from ..< to` (absolute samples) into session-timed words.
    /// nil when the pass failed or was cancelled — the next one retries.
    private func decodeWindow(from: Int, to: Int) async -> [LiveWord]? {
        let lo = from - audioStart, hi = to - audioStart
        guard lo >= 0, hi <= audio.count, hi > lo else { return nil }
        var window = Array(audio[lo..<hi])
        let minimum = Int(tuning.minWindowSeconds * rate)
        if window.count < minimum {
            window.append(contentsOf: [Float](repeating: 0, count: minimum - window.count))
        }
        let raw: [LiveWord]
        do {
            raw = try await decode(window)
        } catch is CancellationError {
            return nil
        } catch {
            fputs("NotchWhisper[live]: decode failed (will retry): \(error)\n", stderr)
            return nil
        }
        let offset = Double(from) / rate
        let limit = Double(to) / rate
        var words = raw.compactMap { word -> LiveWord? in
            guard !word.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let start = min(limit, word.start + offset)
            return LiveWord(text: word.text, start: start, end: max(start, min(limit, word.end + offset)))
        }
        if tuning.isWhisper { words = LiveText.removingAnnotations(words) }
        if from == openStart, let continuation, let first = words.first,
           LiveText.key(first.text) == LiveText.key(continuation.text),
           let c = continuation.text.first(where: { !$0.isWhitespace }), c.isLowercase,
           let index = first.text.firstIndex(where: { !$0.isWhitespace }), first.text[index].isUppercase {
            let finalSoFar = LiveText.text(of: finalWords.suffix(1))
            if let mark = finalSoFar.last, !".?!。？！".contains(mark) {
                words[0].text.replaceSubrange(index...index, with: first.text[index].lowercased())
            }
        }
        return LiveText.deloop(words)
    }

    /// Audio before the open phrase is never decoded again.
    private func trimAudio() {
        let drop = min(openStart - audioStart, audio.count)
        guard drop >= LiveVoiceTracker.sampleRate else { return }
        audio.removeFirst(drop)
        audioStart += drop
        voice.forget(before: openStart - LiveVoiceTracker.sampleRate)
    }
}
