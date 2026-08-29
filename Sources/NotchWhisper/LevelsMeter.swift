import SwiftUI

/// A live horizontal level meter driven by `state.levels` (0…1).
/// Token-bound: spacing, radius, colors, motion all come from Tokens.
struct LevelsMeter: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    var height: CGFloat = 40

    var body: some View {
        let _ = theme.theme   // record bars re-tint on theme change
        HStack(spacing: Tokens.Space.x1) {
            ForEach(0..<state.levels.count, id: \.self) { i in
                let lvl = state.levels[i]
                Capsule()
                    .fill(gradient(for: lvl))
                    .frame(width: 4, height: max(4, CGFloat(lvl) * height))
                    .animation(Tokens.Motion.meter, value: lvl)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .center)
        .padding(.vertical, Tokens.Space.x2)
        .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private func gradient(for lvl: Float) -> SwiftUI.LinearGradient {
        let hot = lvl > 0.75
        return SwiftUI.LinearGradient(
            colors: hot
                ? [Tokens.Color.record, Tokens.Color.recordDark]
                : [Tokens.Color.accent.opacity(0.9), Tokens.Color.accent],
            startPoint: .bottom, endPoint: .top
        )
    }
}

/// A compact circular record button.
struct RecordButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    let action: () -> Void

    private var isActive: Bool {
        state.mode == .recording || state.mode == .dictating
    }

    var body: some View {
        let _ = theme.theme   // re-tint on theme change
        Button(action: action) {
            Label(isActive ? "Stop" : "Record",
                  systemImage: isActive ? "stop.fill" : "mic.fill")
                .font(Tokens.TypeScale.headline)
                .contentTransition(.opacity)
                // Record⇄Stop reads as one control changing, not two controls.
                .symbolFeedback(value: state.mode)
        }
        // Native Liquid Glass prominent button on macOS 26 (the tint colors
        // the glass); native borderedProminent elsewhere. No custom capsule.
        .glassButton(prominent: true)
        .tint(isActive ? Tokens.Color.record : Tokens.Color.accent)
        .controlSize(.large)
        .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: state.mode)
        .help(isActive ? "Stop" : "Start")
    }
}
