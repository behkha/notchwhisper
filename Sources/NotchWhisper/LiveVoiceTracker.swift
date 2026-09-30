import Foundation

/// Streaming speech detection for live dictation: where the speech is in audio
/// that keeps arriving, and how long the speaker has been quiet.
///
/// The same measure as `VoiceActivityDetector` — frame energy against an
/// adaptive noise floor, with a zero-crossing ceiling for hiss — but run
/// incrementally, with the floor taken from the last few seconds rather than
/// from a finished recording. Positions are absolute sample indices from the
/// start of the session, so trimming the audio elsewhere never moves them.
struct LiveVoiceTracker {
    static let sampleRate = 16_000
    /// 20 ms frames.
    static let frameSamples = 320
    /// A burst must last this many frames to count as speech (160 ms): a key
    /// click or a knock on the desk never does.
    static let minSpeechFrames = 8
    /// Quiet frames tolerated inside a run — the gaps inside and between words.
    static let hangoverFrames = 4
    /// How much recent audio the noise floor is measured over (6 s).
    static let floorFrames = 300

    var sensitivity: VoiceActivityDetector.Sensitivity

    private var carry: [Float] = []
    /// Frames analysed so far; frame `i` covers samples `i*320 ..< (i+1)*320`.
    private(set) var frameCount = 0
    private var recentRMS: [Float] = []
    private var run = 0
    private var runStartFrame = 0
    private var gap = 0
    /// Qualifying speech runs, absolute samples, oldest first.
    private(set) var runs: [(start: Int, end: Int)] = []

    init(sensitivity: VoiceActivityDetector.Sensitivity) {
        self.sensitivity = sensitivity
    }

    /// Sample index up to which audio has been analysed.
    var analysedUpTo: Int { frameCount * Self.frameSamples }

    /// Where the most recent speech ended, or nil before anyone spoke.
    var lastSpeechEnd: Int? { runs.last?.end }

    /// True while the audio at the live edge is speech (or a gap short enough
    /// to still be inside a word).
    var isSpeaking: Bool { run > 0 && gap <= Self.hangoverFrames }

    mutating func append(_ samples: [Float]) {
        carry.append(contentsOf: samples)
        var offset = 0
        while carry.count - offset >= Self.frameSamples {
            analyse(carry[offset..<(offset + Self.frameSamples)])
            offset += Self.frameSamples
        }
        carry.removeFirst(offset)
    }

    /// Whether any speech was heard in `from ..< to` (absolute samples).
    func hasSpeech(from: Int, to: Int) -> Bool {
        guard from < to else { return false }
        for r in runs.reversed() {
            if r.end <= from { return false }
            if r.start < to { return true }
        }
        return false
    }

    /// Where the first speech at or after `sample` began (clamped to it).
    func firstSpeechStart(from sample: Int) -> Int? {
        guard let run = runs.first(where: { $0.end > sample }) else { return nil }
        return max(run.start, sample)
    }

    /// The pauses between speech inside `from ..< to` at least `minLength`
    /// samples long, oldest first.
    func gaps(from: Int, to: Int, minLength: Int) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        for i in runs.indices.dropFirst() {
            let gap = (start: runs[i - 1].end, end: runs[i].start)
            if gap.start >= from, gap.end <= to, gap.end - gap.start >= minLength { out.append(gap) }
        }
        return out
    }

    /// Forget runs that ended before `sample` — nothing asks about them again.
    mutating func forget(before sample: Int) {
        runs.removeAll { $0.end < sample }
    }

    private mutating func analyse(_ frame: ArraySlice<Float>) {
        var energy: Float = 0
        var crossings = 0
        var previous = frame.first ?? 0
        for s in frame {
            energy += s * s
            if (s >= 0) != (previous >= 0) { crossings += 1 }
            previous = s
        }
        let rms = (energy / Float(frame.count)).squareRoot()
        let zcr = Float(crossings) / Float(frame.count)

        recentRMS.append(rms)
        if recentRMS.count > Self.floorFrames { recentRMS.removeFirst(recentRMS.count - Self.floorFrames) }
        // The room between words: the 10th percentile of recent frame energy.
        let sorted = recentRMS.sorted()
        let floor = max(sorted[sorted.count / 10], 0.0015)
        let threshold = min(max(floor * sensitivity.multiplier, VoiceActivityDetector.absoluteFloor),
                            VoiceActivityDetector.thresholdCeiling)
        let isSpeech = rms > threshold && zcr < VoiceActivityDetector.zcrCeiling

        let index = frameCount
        frameCount += 1
        if isSpeech {
            if run == 0 { runStartFrame = index }
            run += 1
            gap = 0
            if run >= Self.minSpeechFrames {
                let start = runStartFrame * Self.frameSamples
                let end = (index + 1) * Self.frameSamples
                if let last = runs.last, last.start == start {
                    runs[runs.count - 1].end = end
                } else {
                    runs.append((start, end))
                }
            }
        } else if run > 0 {
            gap += 1
            if gap > Self.hangoverFrames { run = 0; gap = 0 }
        }
    }
}
