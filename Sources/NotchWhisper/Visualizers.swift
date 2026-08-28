import SwiftUI

// MARK: - Audio visualizer styles (LiveKit Agents-UI ports)
//
// Faithful SwiftUI ports of the five AgentAudioVisualizer components from
// LiveKit Agents-UI (livekit/components-js → packages/shadcn):
//
//   agent-audio-visualizer-bar.tsx    + use-agent-audio-visualizer-bar.ts
//   agent-audio-visualizer-grid.tsx   + use-agent-audio-visualizer-grid.ts
//   agent-audio-visualizer-radial.tsx + use-agent-audio-visualizer-radial.ts
//   agent-audio-visualizer-wave.tsx   + use-agent-audio-visualizer-wave.ts
//   agent-audio-visualizer-aura.tsx   + use-agent-audio-visualizer-aura.ts
//
// LiveKit's design language (kept exactly):
//  · Elements sit at 10% opacity (`bg-current/10`); a state-driven highlight
//    sequencer lights elements up to 100% (`bg-current`) — the animation IS
//    the moving highlight, not the spectrum.
//  · Volume drives element SIZE only while state == .speaking.
//  · Wave / Aura default to LiveKit cyan #1FD5F9.
//
// NotchWhisper state mapping: recording → .speaking (the user's voice drives
// the bands), transcribing → .thinking (LiveKit's processing patterns).
//
// Wave is a Canvas port of LiveKit's GLSL oscilloscope shader (bell-curve
// attenuated sine + edge-fade mask). Aura is a Canvas approximation of the
// Unicorn Studio turbulence shader — Command Line Tools ship no Metal
// compiler, so the GLSL cannot be compiled here; layered additive distorted
// rings reproduce the organic glow instead.

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case bar, wave, radial, grid, aura

    var id: String { rawValue }

    var display: String {
        switch self {
        case .bar:    return "Bar"
        case .wave:   return "Wave"
        case .radial: return "Radial"
        case .grid:   return "Grid"
        case .aura:   return "Aura"
        }
    }

    var blurb: String {
        switch self {
        case .bar:    return "Vertical bars that react to audio levels — clean and minimal."
        case .wave:   return "A flowing waveform line — an oscilloscope sine that swells with your voice."
        case .radial: return "A circular visualization that expands outward from a ring of dots."
        case .grid:   return "A grid of cells that pulse with audio — a subtle, compact pattern."
        case .aura:   return "A glowing, organic aura — a pulsing energy field (Unicorn Studio style)."
        }
    }

    init(raw: String?) {
        self = VisualizerStyle(rawValue: raw ?? "") ?? .bar
    }
}

/// LiveKit agent states that drive the visualizer animation patterns.
enum VisualizerAgentState {
    case connecting, listening, thinking, speaking
}

// MARK: - Dispatcher

/// Renders the currently selected visualizer style. Consumed by NotchView in
/// the recording (.speaking) and transcribing (.thinking) phases, and by the
/// Settings preview.
struct AudioVisualizer: View {
    let style: VisualizerStyle
    let state: VisualizerAgentState
    /// 32 band heights 0…1 from WaveformModel.
    let heights: [CGFloat]
    /// Overall volume 0…1 from WaveformModel.
    let energy: CGFloat
    /// Voice-reactive tint for Bar/Grid/Radial (LiveKit's `color` prop).
    /// nil = white. Wave/Aura keep LiveKit's signature cyan.
    let tint: (r: Double, g: Double, b: Double)?
    /// Timeline time in seconds — drives the highlight sequencers + shaders.
    let t: TimeInterval

    var body: some View {
        switch style {
        case .bar:
            LKBarVisualizer(state: state, heights: heights, tint: tint, t: t)
        case .wave:
            LKWaveVisualizer(state: state, energy: energy, t: t)
        case .radial:
            LKRadialVisualizer(state: state, heights: heights, tint: tint, t: t)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity)
        case .grid:
            LKGridVisualizer(state: state, heights: heights, tint: tint, t: t)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity)
        case .aura:
            LKAuraVisualizer(state: state, energy: energy, t: t)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Shared helpers

extension Int {
    /// Positive modulo.
    @inline(__always) fileprivate func wrap(_ m: Int) -> Int { ((self % m) + m) % m }
}

/// Resizes the 32 model bands to exactly `count` entries by averaging
/// overlapping ranges (LiveKit's normalizeVolumeBands equivalent, but for
/// downsampling the Goertzel bank).
private func resampleBands(_ heights: [CGFloat], to count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    guard !heights.isEmpty else { return Array(repeating: 0, count: count) }
    if heights.count == count { return heights }
    var out = [CGFloat](repeating: 0, count: count)
    for i in 0..<count {
        let start = CGFloat(i) * CGFloat(heights.count) / CGFloat(count)
        let end = CGFloat(i + 1) * CGFloat(heights.count) / CGFloat(count)
        var sum: CGFloat = 0
        var weight: CGFloat = 0
        let j0 = Int(start)
        let j1 = min(heights.count - 1, Int(end))
        for j in j0...j1 {
            let coverage = min(end, CGFloat(j + 1)) - max(start, CGFloat(j))
            if coverage > 0 {
                sum += heights[j] * coverage
                weight += coverage
            }
        }
        out[i] = weight > 0 ? sum / weight : 0
    }
    return out
}

/// The LiveKit highlight sequencer. A sequence of "highlighted element" sets
/// is stepped at a fixed interval; an element is lit while its phase is
/// active. `highlighted(_:at:)` evaluates the sequencer deterministically
/// from the timeline clock and applies the CSS-transition-style fades
/// (fade-in when a phase lights the element, fade-out after it leaves).
struct LKSequencer {
    let sequence: [[Int]]
    let interval: TimeInterval

    func highlighted(_ element: Int, at t: TimeInterval,
                     fadeIn: TimeInterval, fadeOut: TimeInterval) -> CGFloat {
        let len = sequence.count
        guard len > 0 else { return 0 }
        guard interval > 0, interval.isFinite else {
            return sequence[0].contains(element) ? 1 : 0
        }
        let phase = Int(floor(t / interval))
        let current = sequence[phase.wrap(len)]

        if current.contains(element) {
            // Walk backwards to the start of the continuous highlight run.
            var start = phase
            var steps = 0
            while steps < len + 1 {
                guard sequence[(start - 1).wrap(len)].contains(element) else { break }
                start -= 1
                steps += 1
            }
            if steps >= len + 1 { return 1 }   // highlighted in every phase
            let tStart = Double(start) * interval
            let fadeInAmount = CGFloat(min(1, max(0, (t - tStart) / max(fadeIn, 0.001))))
            // CSS transitions start from the CURRENT opacity, not zero: if a
            // previous run just ended, blend its residual fade-out underneath.
            var k = start - 1
            for _ in 0..<len {
                if sequence[k.wrap(len)].contains(element) {
                    let tEnd = Double(k + 1) * interval
                    let residual = CGFloat(max(0, 1 - (t - tEnd) / max(fadeOut, 0.001)))
                    return max(fadeInAmount, residual)
                }
                k -= 1
            }
            return fadeInAmount
        } else {
            // Find the most recent phase that lit this element → fade out.
            var k = phase - 1
            for _ in 0..<len {
                if sequence[k.wrap(len)].contains(element) {
                    let tEnd = Double(k + 1) * interval
                    return CGFloat(max(0, 1 - (t - tEnd) / max(fadeOut, 0.001)))
                }
                k -= 1
            }
            return 0
        }
    }
}

@inline(__always)
private func tintColor(_ tint: (r: Double, g: Double, b: Double)?) -> SwiftUI.Color {
    guard let tint else { return .white }
    return SwiftUI.Color(red: tint.r, green: tint.g, blue: tint.b)
}

/// LiveKit cyan #1FD5F9 — the signature Wave/Aura color.
private let lkCyan = SwiftUI.Color(red: 0.12, green: 0.84, blue: 0.98)

// MARK: - Bar (agent-audio-visualizer-bar)

/// Five rounded bars, center-aligned. Idle bars are square dots at 10%
/// opacity; the sequencer lights them while volume grows their height —
/// exactly the LiveKit Bar component (md size proportions: bar width =
/// height/7, gap = width/2, min-height = width).
private struct LKBarVisualizer: View {
    let state: VisualizerAgentState
    let heights: [CGFloat]
    let tint: (r: Double, g: Double, b: Double)?
    let t: TimeInterval

    private static let barCount = 5

    private var sequencer: LKSequencer {
        let n = Self.barCount
        let centerBlink: [[Int]] = n % 2 == 0 ? [[n / 2 - 1, n / 2], []] : [[n / 2], []]
        switch state {
        case .connecting:
            // Mirror pairs closing in from the edges.
            return LKSequencer(sequence: (0..<n).map { [$0, n - 1 - $0] },
                               interval: 2.0 / Double(n))
        case .listening:
            return LKSequencer(sequence: centerBlink, interval: 0.5)
        case .thinking:
            return LKSequencer(sequence: centerBlink, interval: 0.15)
        case .speaking:
            return LKSequencer(sequence: [Array(0..<n)], interval: 1.0)
        }
    }

    var body: some View {
        let bands = resampleBands(heights, to: Self.barCount)
        let seq = sequencer
        Canvas { context, size in
            let n = Self.barCount
            let barW = size.height / 7
            let gap = barW / 2
            let totalW = CGFloat(n) * barW + CGFloat(n - 1) * gap
            let x0 = (size.width - totalW) / 2
            let color = tintColor(tint)
            for i in 0..<n {
                let hl = seq.highlighted(i, at: t, fadeIn: 0.25, fadeOut: 0.25)
                let band: CGFloat = state == .speaking ? bands[i] : 0
                let h = max(barW, band * size.height)
                let rect = CGRect(x: x0 + CGFloat(i) * (barW + gap),
                                  y: (size.height - h) / 2,
                                  width: barW, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(color.opacity(0.10 + 0.90 * Double(hl))))
            }
        }
        .animation(nil, value: heights)
    }
}

// MARK: - Grid (agent-audio-visualizer-grid)

/// A 5×5 grid of round cells. Speaking: cells light symmetrically outward
/// from the middle row as their column's volume crosses a per-row threshold.
/// Otherwise a highlight walks the perimeter (connecting), sweeps the middle
/// row (thinking), or heartbeats the center cell (listening) — fast in,
/// slow out, exactly like the LiveKit Grid component.
private struct LKGridVisualizer: View {
    let state: VisualizerAgentState
    let heights: [CGFloat]
    let tint: (r: Double, g: Double, b: Double)?
    let t: TimeInterval

    private static let cols = 5
    private static let rows = 5
    private static let interval: TimeInterval = 0.1

    private var sequencer: LKSequencer {
        let c = Self.cols
        let r = Self.rows
        switch state {
        case .connecting:
            // Perimeter walk of the outer ring (generateConnectingSequence).
            var seq: [[Int]] = []
            for x in 0..<c { seq.append([x]) }                       // top edge →
            for y in 1..<r { seq.append([y * c + (c - 1)]) }         // right edge ↓
            for x in stride(from: c - 2, through: 0, by: -1) { seq.append([(r - 1) * c + x]) } // bottom ←
            for y in stride(from: r - 2, through: 1, by: -1) { seq.append([y * c]) }           // left ↑
            return LKSequencer(sequence: seq, interval: Self.interval)
        case .listening:
            // Center cell heartbeat: on for one tick, off for eight.
            var seq: [[Int]] = [[(r / 2) * c + c / 2]]
            for _ in 0..<8 { seq.append([]) }
            return LKSequencer(sequence: seq, interval: Self.interval)
        case .thinking:
            // Middle row sweep: left → right → left.
            var seq: [[Int]] = (0..<c).map { [(r / 2) * c + $0] }
            seq += (0..<c).reversed().map { [(r / 2) * c + $0] }
            return LKSequencer(sequence: seq, interval: Self.interval)
        case .speaking:
            return LKSequencer(sequence: [[]], interval: 1.0)
        }
    }

    var body: some View {
        let bands = resampleBands(heights, to: Self.cols)
        let seq = sequencer
        Canvas { context, size in
            let c = Self.cols
            let r = Self.rows
            let side = min(size.width, size.height)
            let cell = side / 9                    // 5 cells + 4 gaps, gap = cell
            let ox = (size.width - side) / 2
            let oy = (size.height - side) / 2
            let color = tintColor(tint)
            let rowMid = r / 2
            let volumeChunks = 1.0 / (CGFloat(rowMid) + 1)

            for y in 0..<r {
                for x in 0..<c {
                    let amount: CGFloat
                    if state == .speaking {
                        // Rows farther from the middle need more volume to light.
                        let threshold = CGFloat(abs(rowMid - y)) * volumeChunks
                        let d = bands[x] - threshold
                        amount = d >= 0 ? 1 : max(0, 1 + d / 0.05)
                    } else {
                        // Fast in (interval), slow out (interval × 10) — the
                        // transitionDuration split from the LiveKit GridCell.
                        amount = seq.highlighted(y * c + x, at: t,
                                                 fadeIn: Self.interval,
                                                 fadeOut: Self.interval * 10)
                    }
                    let cx = ox + cell / 2 + CGFloat(x) * 2 * cell
                    let cy = oy + cell / 2 + CGFloat(y) * 2 * cell
                    let rect = CGRect(x: cx - cell / 2, y: cy - cell / 2,
                                      width: cell, height: cell)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(color.opacity(0.10 + 0.90 * Double(amount))))
                }
            }
        }
        .animation(nil, value: heights)
    }
}

// MARK: - Radial (agent-audio-visualizer-radial)

/// 24 round dots on a ring. Speaking: each dot grows into a capsule outward
/// (up to 10× dot size) with its volume band. Connecting: opposite pairs
/// chase around the circle. Listening: 4-dot groups rotate like clock
/// ticks. Thinking: the whole wheel spins (5 s/turn) fully lit — the
/// LiveKit Radial component's `animate-spin` behavior.
private struct LKRadialVisualizer: View {
    let state: VisualizerAgentState
    let heights: [CGFloat]
    let tint: (r: Double, g: Double, b: Double)?
    let t: TimeInterval

    private static let barCount = 24

    private var sequencer: LKSequencer {
        let n = Self.barCount
        switch state {
        case .connecting:
            // Opposite pairs: [x, (x + n/2) % n].
            return LKSequencer(sequence: (0..<n).map { [$0, ($0 + n / 2) % n] },
                               interval: 0.5)
        case .listening, .thinking:
            // 6 groups of 4 bars (LiveKit's gcd-divisor grouping for n = 24).
            let groups = 6
            let seq: [[Int]] = (0..<groups).map { g in
                (0..<(n / groups)).map { $0 * groups + g }
            }
            return LKSequencer(sequence: seq,
                               interval: state == .listening ? 0.5 : .infinity)
        case .speaking:
            return LKSequencer(sequence: [Array(0..<n)], interval: 1.0)
        }
    }

    var body: some View {
        let bands = resampleBands(heights, to: Self.barCount)
        let seq = sequencer
        Canvas { context, size in
            let n = Self.barCount
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let side = min(size.width, size.height)
            let radius = side * 0.21
            let dot = radius * .pi / CGFloat(n)          // LiveKit: r·π/barCount
            let maxLen = side / 2 - radius - dot / 2     // keep tips in bounds
            let color = tintColor(tint)
            // Thinking: CSS animate-spin, one turn per 5 s, all bars lit.
            let spin: CGFloat = state == .thinking
                ? CGFloat(t.truncatingRemainder(dividingBy: 5)) / 5 * 2 * .pi
                : 0
            for i in 0..<n {
                let angle = CGFloat(i) / CGFloat(n) * 2 * .pi + spin - .pi / 2
                let hl: CGFloat = state == .thinking
                    ? 1
                    : seq.highlighted(i, at: t, fadeIn: 0.15, fadeOut: 0.15)
                let len: CGFloat = state == .speaking
                    ? min(max(dot, dot * 10 * bands[i]), maxLen)
                    : 0.1                                 // idle: just the dot
                let dir = CGPoint(x: cos(angle), y: sin(angle))
                let p0 = CGPoint(x: center.x + dir.x * radius,
                                 y: center.y + dir.y * radius)
                let p1 = CGPoint(x: center.x + dir.x * (radius + len),
                                 y: center.y + dir.y * (radius + len))
                var seg = Path()
                seg.move(to: p0)
                seg.addLine(to: p1)
                context.stroke(seg,
                               with: .color(color.opacity(0.10 + 0.90 * Double(hl))),
                               style: StrokeStyle(lineWidth: dot, lineCap: .round))
            }
        }
        .animation(nil, value: heights)
    }
}

// MARK: - Wave (agent-audio-visualizer-wave)

/// Canvas port of the LiveKit Wave GLSL shader: a traveling sine whose
/// amplitude is attenuated by a cos¹⁶ bell curve toward the edges, drawn
/// through the same edge-fade mask (transparent 0–20%, opaque 20–80%,
/// transparent 80–100%). State parameters are the exact values from
/// use-agent-audio-visualizer-wave.ts; speaking maps volume → amplitude
/// (0.015 + 0.4·v) and frequency (20 + 60·v).
private struct LKWaveVisualizer: View {
    let state: VisualizerAgentState
    let energy: CGFloat
    let t: TimeInterval

    var body: some View {
        Canvas { context, size in
            let speed: Double
            let amplitude: Double
            let frequency: Double
            let opacity: Double
            switch state {
            case .speaking:
                speed = 10
                amplitude = 0.015 + 0.4 * Double(energy)
                frequency = 20 + 60 * Double(energy)
                opacity = 1
            case .listening:
                speed = 5; amplitude = 0.025; frequency = 10
                opacity = 0.65 + 0.35 * sin(t * 2 * .pi / 1.5)   // 0.75 s mirror pulse
            case .thinking, .connecting:
                speed = 20; amplitude = 0.025 / 4; frequency = 40
                opacity = 0.65 + 0.35 * sin(t * 2 * .pi / 0.8)   // 0.4 s mirror pulse
            }

            var path = Path()
            let samples = 220
            for s in 0...samples {
                let u = Double(s) / Double(samples)
                let relX = u - 0.5
                let bell = pow(cos(min(1, abs(relX) / 0.5) * .pi / 4), 16)
                let yUV = 0.5 + sin(relX * frequency + t * speed) * amplitude * bell
                let pt = CGPoint(x: u * size.width, y: yUV * size.height)
                if s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }

            let stops: [Gradient.Stop] = [
                .init(color: lkCyan.opacity(0), location: 0),
                .init(color: lkCyan.opacity(opacity), location: 0.2),
                .init(color: lkCyan.opacity(opacity), location: 0.8),
                .init(color: lkCyan.opacity(0), location: 1),
            ]
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: stops),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )

            // Soft bloom under the crisp line.
            var bloom = context
            bloom.addFilter(.blur(radius: 3))
            bloom.opacity = 0.4
            bloom.stroke(path, with: shading,
                         style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            context.stroke(path, with: shading,
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .animation(nil, value: energy)
    }
}

// MARK: - Aura (agent-audio-visualizer-aura)

/// Canvas approximation of the Unicorn Studio turbulence shader behind the
/// LiveKit Aura component (the real thing is GLSL; no Metal compiler ships
/// with Command Line Tools, so it can't be compiled here). 26 additively
/// blended distorted rings — each displaced by a 4-layer sinusoidal
/// turbulence cascade, matching the shader's frequency growth (×1.4/layer)
/// and iteration spacing — form the organic glowing field. State parameters
/// (speed / scale / amplitude / frequency / brightness) are the exact
/// values from use-agent-audio-visualizer-aura.ts, including the thinking
/// brightness pulse (0.5↔2.5) and speaking scale (0.2 + 0.2·volume).
private struct LKAuraVisualizer: View {
    let state: VisualizerAgentState
    let energy: CGFloat
    let t: TimeInterval

    /// Hue-shifted companion of lkCyan for per-layer color variation.
    private static let shifted = (r: 0.42, g: 0.55, b: 1.0)

    var body: some View {
        Canvas { context, size in
            let speed: Double
            let scale: Double
            let amp: Double
            let freq: Double
            let brightness: Double
            switch state {
            case .speaking:
                speed = 70
                scale = 0.2 + 0.2 * Double(energy)
                amp = 0.75; freq = 1.25; brightness = 1.5
            case .listening:
                speed = 20; scale = 0.3; amp = 1.0; freq = 0.7
                brightness = 1.75 + 0.25 * sin(t * 2 * .pi / 0.7)
            case .thinking, .connecting:
                speed = 30; scale = 0.3; amp = 0.5; freq = 1.0
                brightness = 1.5 + 1.0 * sin(t * 2 * .pi / 0.7)
            }

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let side = min(size.width, size.height)
            let baseR = side * scale * 0.9
            let evolve = t * speed * 0.03
            let baseF = 2.0 + 13.0 * freq            // shader: mix(2, 15, uFrequency)
            let norm = max(0, brightness) / 2.5
            let layers = 26

            context.blendMode = .plusLighter

            var bloom = context
            bloom.addFilter(.blur(radius: 5))
            bloom.opacity = 0.5

            for pass in 0..<2 {                       // 0 = bloom, 1 = crisp
                let ctx = pass == 0 ? bloom : context
                for k in 0..<layers {
                    let iter = Double(k) / Double(layers)
                    let phaseK = iter * .pi           // shader uSpacing 0.5 → ≈π
                    // Per-layer hue drift (shader uColorShift).
                    let mixV = (1 - iter) * 0.35
                    let col = SwiftUI.Color(
                        red: 0.12 + (Self.shifted.r - 0.12) * mixV,
                        green: 0.84 + (Self.shifted.g - 0.84) * mixV,
                        blue: 0.98 + (Self.shifted.b - 0.98) * mixV
                    )
                    let alpha = pass == 0 ? 0.05 + 0.10 * norm : 0.04 + 0.12 * norm

                    var ring = Path()
                    let steps = 64
                    for s in 0...steps {
                        let theta = Double(s) / Double(steps) * 2 * .pi
                        // 4-layer turbulence cascade.
                        var f = baseF
                        var a = amp * 0.13
                        var disp = 0.0
                        for L in 0..<4 {
                            disp += a * sin(f * cos(theta + Double(L) * 1.9)
                                            + evolve * (0.6 + 0.4 * Double(L))
                                            + phaseK * (1 + 0.3 * Double(L)))
                            f *= 1.4
                            a *= 0.72
                        }
                        let rr = baseR * (1 + max(-0.33, min(0.33, disp)))
                        let pt = CGPoint(x: center.x + cos(theta + iter * 0.6) * rr,
                                         y: center.y + sin(theta + iter * 0.6) * rr)
                        if s == 0 { ring.move(to: pt) } else { ring.addLine(to: pt) }
                    }
                    ring.closeSubpath()
                    ctx.stroke(ring, with: .color(col.opacity(alpha)),
                               lineWidth: pass == 0 ? 3.5 : 1.1)
                }
            }

            // Soft core glow.
            let glowR = baseR * 0.55
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - glowR, y: center.y - glowR,
                                       width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [lkCyan.opacity(0.04 + 0.10 * norm), .clear]),
                    center: center, startRadius: 0, endRadius: glowR
                )
            )
        }
    }
}

// MARK: - Settings preview

/// A self-contained animated preview of a visualizer style for the Settings
/// window. Simulates a speech-like spectrum (no mic needed): two drifting
/// formant bumps over a decaying tilt, gated by a speech rhythm. Shows the
/// .speaking behavior with LiveKit's default colors (white / cyan).
struct VisualizerPreview: View {
    let style: VisualizerStyle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let frame = Self.simulatedFrame(t: t)
            AudioVisualizer(
                style: style,
                state: .speaking,
                heights: frame.heights,
                energy: frame.energy,
                tint: nil,
                t: t
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }

    private static func simulatedFrame(t: TimeInterval) -> (heights: [CGFloat], energy: CGFloat) {
        let n = WaveformModel.barCount
        var heights = [CGFloat](repeating: 0, count: n)
        let gate = 0.55 + 0.45 * sin(t * 2.4)
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1)
            let tilt = 1.0 - 0.5 * u
            let b1 = exp(-pow(u - CGFloat(0.22 + 0.06 * sin(t * 1.3)), 2) / 0.004)
            let b2 = exp(-pow(u - CGFloat(0.55 + 0.08 * sin(t * 0.9 + 1.2)), 2) / 0.006)
            let jitter = 0.85 + 0.15 * sin(t * 11 + CGFloat(i) * 1.9)
            heights[i] = min(1, max(0.05, (0.25 * tilt + 0.65 * b1 + 0.45 * b2) * gate * jitter))
        }
        let energy = CGFloat(0.35 + 0.30 * gate)
        return (heights, energy)
    }
}
