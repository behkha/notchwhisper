import Foundation
import SwiftUI

/// Spectrum-driven bar waveform model.
///
/// The mic's raw 16 kHz samples are analyzed into 32 FIXED frequency bands
/// (Goertzel filter bank, log-spaced 70 Hz…7.5 kHz). Bar *i* shows the energy
/// of band *i* — low pitches move the LEFT bars, high pitches move the RIGHT
/// bars. Every bar stays in place; only its height moves. There is NO
/// time-based horizontal motion anywhere (no traveling wave, no ripple).
///
/// · fast attack / smooth release per bar → bars jump when you speak and
///   settle gently when you stop
/// · energy — smoothed overall loudness (from the RMS meter)
/// · glow   — a slower envelope over energy, driving the voice-reactive halo
///
/// Ticks at 60 Hz on the main queue. The published `frame` is consumed by a
/// Canvas in NotchView — no implicit SwiftUI animations anywhere.
@MainActor
final class WaveformModel: ObservableObject {
    struct Frame: Equatable {
        var heights: [CGFloat]
        var energy: CGFloat
        /// Slower-smoothed energy that drives the voice-reactive halo glow.
        var glow: CGFloat
    }

    static let barCount = 32

    @Published private(set) var frame = Frame(
        heights: Array(repeating: 0.04, count: WaveformModel.barCount),
        energy: 0,
        glow: 0
    )

    // MARK: - Spectrum analysis (Goertzel filter bank)
    private static let sampleRate: Float = 16000
    private static let windowSize = 512                      // 32 ms window
    /// Log-spaced center frequencies: 70 Hz (leftmost bar) … 7.5 kHz (rightmost).
    private static let bandFreqs: [Float] = (0..<barCount).map { b in
        70 * pow(7500 / 70, Float(b) / Float(barCount - 1))
    }

    private var sampleRing: [Float] = []
    private var dirty = false
    /// True once real mic samples arrive; gates the synthetic preview shape.
    private var hasRealSamples = false
    private var lastInput = Date.distantPast

    // MARK: - Animation state
    private var current: [CGFloat] = Array(repeating: 0.04, count: barCount)
    private var bandTargets: [CGFloat] = Array(repeating: 0, count: barCount)
    private var energyCurrent: CGFloat = 0
    private var energyTarget: CGFloat = 0
    private var glowCurrent: CGFloat = 0
    private var timer: DispatchSourceTimer?

    private let noiseFloor: Float = 0.04

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        energyCurrent = 0
        energyTarget = 0
        glowCurrent = 0
        sampleRing = []
        dirty = false
        hasRealSamples = false
        bandTargets = Array(repeating: 0, count: Self.barCount)
        current = Array(repeating: 0.04, count: Self.barCount)
        frame = Frame(heights: current, energy: 0, glow: 0)
    }

    // MARK: - Inputs

    /// Feed raw 16 kHz mono samples from the recorder. Analyzed on the next
    /// 60 Hz tick into the 32 band targets.
    func appendSamples(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        sampleRing.append(contentsOf: chunk)
        if sampleRing.count > Self.windowSize {
            sampleRing.removeFirst(sampleRing.count - Self.windowSize)
        }
        dirty = true
        hasRealSamples = true
        lastInput = Date()
    }

    /// Feed RMS levels (0…1) from the audio meter. Always updates the overall
    /// loudness (`energyTarget`). Band targets are synthesized from it ONLY
    /// when no real spectrum data is flowing (the --wave-preview simulation);
    /// during real recording the Goertzel bank owns the bars.
    func setLevels(_ levels: [Float]) {
        guard !levels.isEmpty else {
            energyTarget = 0
            if !hasRealSamples { bandTargets = Array(repeating: 0, count: Self.barCount) }
            return
        }
        let avg = levels.reduce(0, +) / Float(levels.count)
        let gated = max(0, avg - noiseFloor) / (1 - noiseFloor)
        energyTarget = min(1, CGFloat(gated).squareRoot() * 1.2)
        lastInput = Date()

        guard !hasRealSamples else { return }
        // Preview fallback: a STATIC speech-like tilt (strong lows, falling
        // highs). No time variation → bars move vertically only.
        for i in 0..<Self.barCount {
            let x = CGFloat(i) / CGFloat(Self.barCount - 1)
            bandTargets[i] = energyTarget * (1.0 - 0.55 * x)
        }
    }

    // MARK: - Tick

    private func step() {
        // Re-analyze the spectrum whenever new audio arrived.
        if dirty, sampleRing.count >= Self.windowSize {
            analyzeSpectrum()
            dirty = false
        }
        // Input went quiet → let the targets fall so the bars settle.
        if Date().timeIntervalSince(lastInput) > 0.12 {
            for i in 0..<Self.barCount { bandTargets[i] *= 0.80 }
            energyTarget *= 0.80
        }

        // Energy: rises quickly when you speak, decays slowly when you stop.
        let eFactor: CGFloat = energyTarget > energyCurrent ? 0.34 : 0.07
        energyCurrent += (energyTarget - energyCurrent) * eFactor

        // Glow: a slower envelope over the same signal — the halo breathes.
        let gFactor: CGFloat = energyTarget > glowCurrent ? 0.16 : 0.045
        glowCurrent += (energyTarget - glowCurrent) * gFactor

        // Bars: each one eases toward its own band target. Fast attack,
        // smooth release. No horizontal coupling between bars.
        var heights = current
        for i in 0..<Self.barCount {
            let target = bandTargets[i]
            let c = current[i]
            let factor: CGFloat = target > c ? 0.50 : 0.14
            heights[i] = max(0.03, c + (target - c) * factor)
        }
        current = heights
        frame = Frame(heights: heights, energy: energyCurrent, glow: glowCurrent)
    }

    /// Goertzel power in each of the 32 log-spaced bands over the last
    /// 512 samples, pre-emphasized, normalized to 0…1 (dB scale + sqrt).
    ///
    /// Tuning notes (validated against synthetic speech in /tmp/goertzel_test):
    /// · pre-emphasis 0.5 (NOT 0.95 — that crushed the voice band by up to
    ///   27 dB and made normal speech read as silence)
    /// · -62 dB floor / 48 dB range + 1.25 gain → normal speech fills the
    ///   bars to ~0.7–0.9, quiet speech still visibly moves them
    private func analyzeSpectrum() {
        let window = sampleRing
        let n = window.count
        guard n > 1 else { return }

        // Mild pre-emphasis lifts highs for pitch visibility without killing lows.
        var pe = [Float](repeating: 0, count: n)
        pe[0] = window[0]
        for i in 1..<n { pe[i] = window[i] - 0.5 * window[i - 1] }

        var bands = [CGFloat](repeating: 0, count: Self.barCount)
        for b in 0..<Self.barCount {
            let omega = 2.0 * Float.pi * Self.bandFreqs[b] / Self.sampleRate
            let coeff = 2.0 * cos(omega)
            var s1: Float = 0, s2: Float = 0
            for i in 0..<n {
                let s0 = pe[i] + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2) / Float(n * n)
            let db = 10 * log10(power + 1e-12)
            let norm = (db + 62) / 48 * 1.25     // -62 dB floor, 48 dB range, +gain
            bands[b] = CGFloat(min(1, max(0, norm)).squareRoot())
        }
        bandTargets = bands
    }
}
