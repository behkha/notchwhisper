import Foundation

/// Energy + zero-crossing voice activity detection over the app's 16 kHz mono
/// audio (spec 04).
///
/// Whisper hallucinates on silence — "Thank you.", "Thanks for watching!" — so
/// an accidental brush of the hotkey used to type a sentence the user never
/// said. This gate decides whether a capture contains speech at all, where the
/// speech starts and ends, and whether a suspicious transcript came from
/// marginal audio.
///
/// A pure function over `[Float]`: no `AppState`, no `Settings`, so it is
/// testable without a microphone (`--vad-selftest`).
struct VoiceActivityDetector {

    /// How loud a frame must be, relative to the room, to count as speech.
    /// Plain words rather than decibels, like `ModeCreativity`.
    enum Sensitivity: String, Codable, CaseIterable, Identifiable {
        case low, normal, high

        var id: String { rawValue }

        var label: String {
            switch self {
            case .low:    return "Low"
            case .normal: return "Normal"
            case .high:   return "High"
            }
        }

        var blurb: String {
            switch self {
            case .low:    return "Lets quiet voices through. Pick this for a soft speaker or a distant mic."
            case .normal: return "Speech well above the room's background noise."
            case .high:   return "Only clear, close speech. Pick this in a loud room."
            }
        }

        /// RMS multiplier over the adaptive noise floor.
        var multiplier: Float {
            switch self {
            case .low:    return 2.5
            case .normal: return 3.5
            case .high:   return 5.0
            }
        }

        /// One step more permissive.
        var lowered: Sensitivity {
            switch self {
            case .high:   return .normal
            case .normal: return .low
            case .low:    return .low
            }
        }
    }

    struct Analysis: Equatable {
        var speechFrames = 0
        var totalFrames = 0
        /// Share of frames that carried speech.
        var speechRatio: Double = 0
        /// Samples before the first speech run.
        var leadingSilence = 0
        /// Samples after the last speech run.
        var trailingSilence = 0
        var peakRMS: Float = 0
        var noiseFloor: Float = 0
        var hasSpeech = false
        var durationSeconds: Double = 0

        /// The audio was too quiet or too sparse to trust a suspicious
        /// transcript — the hallucination list applies.
        var isMarginal: Bool {
            !hasSpeech || speechRatio < 0.15 || peakRMS < VoiceActivityDetector.marginalPeakRMS
        }
    }

    var sensitivity: Sensitivity = .normal

    static let sampleRate = 16_000
    /// 30 ms frames on a 10 ms hop.
    static let frameSamples = 480
    static let hopSamples = 160
    /// Consecutive speech frames (hop units) before a capture counts as
    /// containing speech: ~180 ms. One frame of a keyboard click never qualifies.
    static let minSpeechRun = 15
    /// Non-speech frames tolerated inside a run — the gaps inside a word.
    static let hangoverFrames = 3
    /// Kept on each side of the speech when trimming: Whisper degrades when a
    /// word starts on sample zero.
    static let paddingSamples = 1_920      // 120 ms
    /// The threshold never drops below this, so a perfectly silent room does
    /// not make it zero…
    static let absoluteFloor: Float = 0.005
    /// …and never rises above this, so a loud room cannot gate everything.
    static let thresholdCeiling: Float = 0.06
    /// Hiss and fan noise cross zero far more often than voiced speech.
    static let zcrCeiling: Float = 0.45
    static let marginalPeakRMS: Float = 0.02

    // MARK: Analysis

    func analyse(_ samples: [Float]) -> Analysis {
        var result = Analysis()
        result.durationSeconds = Double(samples.count) / Double(Self.sampleRate)
        guard samples.count >= Self.frameSamples else {
            result.leadingSilence = samples.count
            return result
        }
        let count = (samples.count - Self.frameSamples) / Self.hopSamples + 1
        var rms = [Float](repeating: 0, count: count)
        var zcr = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<count {
                let start = frame * Self.hopSamples
                var energy: Float = 0
                var crossings = 0
                var previous = buffer[start]
                for i in start..<(start + Self.frameSamples) {
                    let s = buffer[i]
                    energy += s * s
                    if (s >= 0) != (previous >= 0) { crossings += 1 }
                    previous = s
                }
                rms[frame] = (energy / Float(Self.frameSamples)).squareRoot()
                zcr[frame] = Float(crossings) / Float(Self.frameSamples)
            }
        }
        result.totalFrames = count
        result.peakRMS = rms.max() ?? 0

        // Adaptive floor: the 10th percentile of frame energy — what the room
        // sounds like between words.
        let sorted = rms.sorted()
        let floor = max(sorted[count / 10], 0.0015)
        result.noiseFloor = floor
        let threshold = min(max(floor * sensitivity.multiplier, Self.absoluteFloor), Self.thresholdCeiling)

        var run = 0
        var runStart = 0
        var gap = 0
        var firstSpeech = -1
        var lastSpeech = -1
        for frame in 0..<count {
            let isSpeech = rms[frame] > threshold && zcr[frame] < Self.zcrCeiling
            if isSpeech {
                result.speechFrames += 1
                if run == 0 { runStart = frame }
                run += 1
                gap = 0
                if run >= Self.minSpeechRun {
                    if firstSpeech < 0 { firstSpeech = runStart }
                    lastSpeech = frame
                }
            } else {
                gap += 1
                if gap > Self.hangoverFrames { run = 0 }
            }
        }
        result.hasSpeech = firstSpeech >= 0
        result.speechRatio = Double(result.speechFrames) / Double(count)
        if result.hasSpeech {
            result.leadingSilence = max(0, firstSpeech * Self.hopSamples)
            let lastEnd = lastSpeech * Self.hopSamples + Self.frameSamples
            result.trailingSilence = max(0, samples.count - lastEnd)
        } else {
            result.leadingSilence = samples.count
        }
        return result
    }

    /// Leading and trailing silence removed, `paddingSamples` kept on each
    /// side. Audio with no detected speech comes back unchanged — trimming is
    /// a favour to the decoder, never a judgement.
    func trimmed(_ samples: [Float], analysis: Analysis? = nil) -> [Float] {
        let a = analysis ?? analyse(samples)
        guard a.hasSpeech else { return samples }
        let start = max(0, a.leadingSilence - Self.paddingSamples)
        let end = min(samples.count, samples.count - a.trailingSilence + Self.paddingSamples)
        guard start < end, start > 0 || end < samples.count else { return samples }
        return Array(samples[start..<end])
    }

    // MARK: Windowing

    /// A place to end a decode window without cutting a word: the midpoint of
    /// the latest quiet stretch of at least `minGapSeconds` inside the last
    /// `searchBackSeconds` of `samples`. nil when the tail is all speech.
    func quietCut(_ samples: [Float], noiseFloor: Float,
                  searchBackSeconds: Double = 8, minGapSeconds: Double = 0.3) -> Int? {
        let searchBack = min(samples.count, Int(searchBackSeconds * Double(Self.sampleRate)))
        let region = samples.count - searchBack
        guard searchBack >= Self.frameSamples else { return nil }
        let threshold = min(max(max(noiseFloor, 0.0015) * sensitivity.multiplier, Self.absoluteFloor), Self.thresholdCeiling)
        let count = (searchBack - Self.frameSamples) / Self.hopSamples + 1
        let minGap = max(1, Int(minGapSeconds * Double(Self.sampleRate)) / Self.hopSamples)
        var best: (start: Int, length: Int)? = nil
        var run = 0
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<count {
                let start = region + frame * Self.hopSamples
                var energy: Float = 0
                for i in start..<(start + Self.frameSamples) { energy += buffer[i] * buffer[i] }
                let quiet = (energy / Float(Self.frameSamples)).squareRoot() <= threshold
                run = quiet ? run + 1 : 0
                if run >= minGap { best = (frame - run + 1, run) }   // latest qualifying stretch wins
            }
        }
        guard let best else { return nil }
        let middle = best.start + best.length / 2
        return region + middle * Self.hopSamples + Self.frameSamples / 2
    }

    // MARK: Hallucinations

    /// What Whisper says when nobody said anything. Checked ONLY against
    /// marginal audio — "thank you" is a real thing people dictate.
    static let hallucinationPhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching",
        "thank you for watching", "thanks for listening", "you", "bye", "bye bye",
        "the end", "so", "okay", "ok", "um", "uh", "hmm", "yeah", "oh",
        "please subscribe", "like and subscribe",
    ]

    static func isLikelyHallucination(_ text: String, analysis: Analysis) -> Bool {
        guard analysis.isMarginal else { return false }
        let normalized = normalize(text)
        if normalized.isEmpty { return true }
        if hallucinationPhrases.contains(normalized) { return true }
        if normalized.hasPrefix("subtitles by") || normalized.hasPrefix("subtitle by")
            || normalized.contains("amara org") || normalized.hasPrefix("transcribed by")
            || normalized.hasPrefix("translated by") {
            return true
        }
        return false
    }

    /// Lowercased, letters/digits/spaces only, whitespace collapsed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var lastSpace = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Self-test

/// `--vad-selftest`: the gate over synthesised buffers, no microphone needed.
enum VoiceActivitySelfTest {
    static func run() -> Int32 {
        let rate = VoiceActivityDetector.sampleRate
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            if !ok { failures += 1 }
        }
        var rng = SystemRandomNumberGenerator()
        func noise(_ n: Int, amplitude: Float) -> [Float] {
            (0..<n).map { _ in Float.random(in: -1...1, using: &rng) * amplitude }
        }
        func silence(_ n: Int) -> [Float] { noise(n, amplitude: 0.0005) }
        /// Harmonic tone under a syllable-rate envelope: low zero-crossing
        /// rate, like voiced speech.
        func voice(_ n: Int, amplitude: Float = 0.2) -> [Float] {
            (0..<n).map { i in
                let t = Float(i) / Float(rate)
                let envelope = 0.6 + 0.4 * sin(2 * Float.pi * 4 * t)
                var s: Float = 0
                for h in 1...6 { s += sin(2 * Float.pi * 130 * Float(h) * t) / Float(h) }
                return s * amplitude * envelope
            }
        }
        let detector = VoiceActivityDetector()

        let quiet = silence(2 * rate)
        let a1 = detector.analyse(quiet)
        check("silence has no speech", !a1.hasSpeech, "ratio=\(a1.speechRatio)")

        let burst = silence(rate) + voice(rate * 3 / 10) + silence(rate)
        let a2 = detector.analyse(burst)
        check("300 ms burst has speech", a2.hasSpeech, "frames=\(a2.speechFrames)")
        check("leading silence ≈ 1 s", abs(a2.leadingSilence - rate) <= 1_600, "lead=\(a2.leadingSilence)")
        check("trailing silence ≈ 1 s", abs(a2.trailingSilence - rate) <= 1_600, "trail=\(a2.trailingSilence)")
        let trimmed = detector.trimmed(burst, analysis: a2)
        let expected = rate * 3 / 10 + 2 * VoiceActivityDetector.paddingSamples
        check("trimmed keeps burst + padding", abs(trimmed.count - expected) <= 2_400,
              "count=\(trimmed.count) expected≈\(expected)")

        var click = silence(2 * rate)
        for i in rate..<(rate + 16) { click[i] = 0.9 }
        let a3 = detector.analyse(click)
        check("click is not speech", !a3.hasSpeech, "frames=\(a3.speechFrames)")

        let hiss = noise(2 * rate, amplitude: 0.03)
        let a4 = detector.analyse(hiss)
        check("constant hiss is not speech", !a4.hasSpeech, "ratio=\(a4.speechRatio)")

        check("\"Thank you.\" on silence is a hallucination",
              VoiceActivityDetector.isLikelyHallucination("Thank you.", analysis: a1))
        let a5 = detector.analyse(silence(rate / 2) + voice(rate * 2) + silence(rate / 2))
        check("\"Thank you.\" over real speech is kept",
              !VoiceActivityDetector.isLikelyHallucination("Thank you.", analysis: a5), "ratio=\(a5.speechRatio)")
        check("♪ on silence is dropped", VoiceActivityDetector.isLikelyHallucination("♪", analysis: a1))
        check("a real sentence over speech is kept",
              !VoiceActivityDetector.isLikelyHallucination("Ship the parser on Friday.", analysis: a5))

        let quietVoice = VoiceActivityDetector(sensitivity: .low)
            .analyse(silence(rate) + voice(rate / 2, amplitude: 0.03) + silence(rate))
        check("quiet voice passes at low sensitivity", quietVoice.hasSpeech, "peak=\(quietVoice.peakRMS)")

        print(failures == 0 ? "vad-selftest: all checks passed" : "vad-selftest: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
