import SwiftUI

/// A live horizontal level meter driven by `state.levels` (0…1), rendered as a
/// row of centered capsules on a glass strip.
struct LevelsMeter: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    var height: CGFloat = 44

    private var active: Bool {
        state.mode == .recording || state.mode == .dictating
    }

    var body: some View {
        let _ = theme.theme
        GeometryReader { geo in
            let n = state.levels.count
            let gap: CGFloat = 3
            let w = max(3, (geo.size.width - CGFloat(n - 1) * gap) / CGFloat(n))
            HStack(spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    let lvl = CGFloat(state.levels[i])
                    Capsule()
                        .fill(barFill(lvl))
                        .frame(width: w, height: max(4, lvl * (height - 6)))
                        .animation(Tokens.Motion.meter, value: lvl)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .center)
        }
        .frame(height: height)
        .padding(.horizontal, Tokens.Space.x3)
        .frame(maxWidth: .infinity)
        .background(Tokens.Color.fillQuieter, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        .opacity(active ? 1 : 0.5)
    }

    private func barFill(_ lvl: CGFloat) -> LinearGradient {
        let hot = lvl > 0.72
        return LinearGradient(
            colors: hot
                ? [Tokens.Color.record, Tokens.Color.recordDark]
                : [Tokens.Color.accent, Tokens.Color.accent.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// The hero record control: a large circular button. Idle shows the accent
/// gradient + mic; recording shows red + a stop glyph and a breathing ring.
struct RecordButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    let action: () -> Void

    private var isActive: Bool { state.mode == .recording || state.mode == .dictating }
    private var isBusy: Bool { state.mode == .transcribing || state.mode == .improving }

    var body: some View {
        let _ = theme.theme
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? AnyShapeStyle(Tokens.Color.record) : AnyShapeStyle(Tokens.Color.accentGradient))
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: (isActive ? Tokens.Color.record : Tokens.Color.accent).opacity(0.45),
                            radius: 16, y: 6)
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(isActive ? .white : Tokens.Color.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 68, height: 68)
        }
        .buttonStyle(.plain)
        .overlay {
            if isActive && !Tokens.A11y.reduceMotion {
                Circle()
                    .stroke(Tokens.Color.record.opacity(0.5), lineWidth: 2)
                    .frame(width: 68, height: 68)
                    .scaleEffect(pulse ? 1.4 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .allowsHitTesting(false)
            }
        }
        .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: state.mode)
        .help(isActive ? "Stop" : "Start")
    }

    @State private var pulse = false
}
