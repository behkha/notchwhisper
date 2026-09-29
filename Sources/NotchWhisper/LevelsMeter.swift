import SwiftUI

/// A live level meter driven by `state.levels` (0…1): fine bars mirrored
/// about a centre line in a recessed well — an oscilloscope, not a toy. At
/// rest it settles to a quiet dotted baseline.
struct LevelsMeter: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    var height: CGFloat = 44
    /// Show the signal even when no dictation is running (the Models lab
    /// records through the shared recorder without changing `state.mode`).
    var live = false

    private var active: Bool {
        live || state.mode == .recording || state.mode == .dictating
    }

    private static let barWidth: CGFloat = 2.5
    private static let pitch: CGFloat = 6

    var body: some View {
        let _ = theme.theme
        GeometryReader { geo in
            let count = max(8, Int((geo.size.width + Self.pitch - Self.barWidth) / Self.pitch))
            let samples = resample(state.levels, to: count)
            let inset = (geo.size.width - (CGFloat(count - 1) * Self.pitch + Self.barWidth)) / 2
            HStack(spacing: Self.pitch - Self.barWidth) {
                ForEach(0..<count, id: \.self) { i in
                    let lvl = active ? CGFloat(samples[i]) : 0
                    Capsule()
                        .fill(barColor(lvl))
                        .frame(width: Self.barWidth,
                               height: max(2.5, lvl * (height - 14)))
                }
            }
            .padding(.leading, max(0, inset))
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .animation(Tokens.Motion.meter, value: active ? samples : [])
        }
        .frame(height: height)
        .padding(.horizontal, Tokens.Space.x4)
        .frame(maxWidth: .infinity)
        .background(Tokens.Color.black(0.25), in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Tokens.Color.black(0.3), Tokens.Color.white(0.05)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(active ? "Listening" : "Idle")
    }

    private func barColor(_ lvl: CGFloat) -> SwiftUI.Color {
        guard active else { return Tokens.Color.textQuat }
        if lvl > 0.72 { return Tokens.Color.record }
        return Tokens.Color.accent.opacity(0.55 + 0.45 * Double(min(1, lvl * 1.6)))
    }

    /// Linear resample of the level ring onto `count` bars, shaped by a soft
    /// window so the signal swells in the middle like a real waveform.
    private func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard levels.count > 1, count > 1 else { return Array(repeating: 0, count: max(count, 1)) }
        let last = Float(levels.count - 1)
        return (0..<count).map { i in
            let t = Float(i) / Float(count - 1)
            let x = t * last
            let lo = Int(x.rounded(.down))
            let hi = min(lo + 1, levels.count - 1)
            let f = x - Float(lo)
            let v = levels[lo] * (1 - f) + levels[hi] * f
            let window = 0.45 + 0.55 * sin(Float.pi * t)
            return min(1, max(0, v * window))
        }
    }
}

/// The hero record control: a lit, machined disc. Idle it wears the accent
/// with a microphone; live it turns record-red with a stop glyph and a slow
/// ripple; busy it shows a spinner.
struct RecordButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    let action: () -> Void
    @ViewState private var hovering = false
    @ViewState private var pulse = false

    private var isActive: Bool { state.mode == .recording || state.mode == .dictating }
    private var isBusy: Bool { state.mode == .transcribing || state.mode == .improving }
    private static let size: CGFloat = 72

    var body: some View {
        let _ = theme.theme
        Button(action: action) {
            ZStack {
                // Bezel: a thin lit ring the disc sits in.
                Circle()
                    .strokeBorder(LinearGradient(colors: [Tokens.Color.white(0.16), Tokens.Color.white(0.03)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
                    .frame(width: Self.size + 12, height: Self.size + 12)
                Circle()
                    .fill(isActive
                          ? AnyShapeStyle(LinearGradient(colors: [Tokens.Color.record, Tokens.Color.recordDark],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Tokens.Color.accentGradient))
                    .overlay(
                        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.02)],
                                                             startPoint: .top, endPoint: .bottom),
                                              lineWidth: 1)
                    )
                    .shadow(color: (isActive ? Tokens.Color.record : Tokens.Color.accent).opacity(0.38),
                            radius: hovering ? 18 : 14, y: 6)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: Self.size, height: Self.size)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: isActive ? 20 : 24, weight: .semibold))
                        .foregroundStyle(isActive ? .white : Tokens.Color.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .brightness(hovering ? 0.03 : 0)
            .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.95))
        .onHover { inside in withAnimation(Tokens.Motion.hover) { hovering = inside } }
        .overlay {
            if isActive && !Tokens.A11y.reduceMotion {
                Circle()
                    .stroke(Tokens.Color.record.opacity(0.5), lineWidth: 1.5)
                    .frame(width: Self.size, height: Self.size)
                    .scaleEffect(pulse ? 1.45 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
                    .allowsHitTesting(false)
            }
        }
        .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: state.mode)
        .help(isActive ? "Stop" : "Start recording")
        .accessibilityLabel(isActive ? "Stop recording" : "Start recording")
    }
}
