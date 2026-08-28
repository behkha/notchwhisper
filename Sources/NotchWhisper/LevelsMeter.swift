import SwiftUI

/// A live horizontal level meter driven by `state.levels` (0…1).
/// Token-bound: spacing, radius, colors, motion all come from Tokens.
struct LevelsMeter: View {
    @EnvironmentObject private var state: AppState
    var height: CGFloat = 40

    var body: some View {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: state.mode == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(state.mode == .recording ? "Stop" : "Record")
                    .font(Tokens.TypeScale.headline)
            }
            .foregroundStyle(state.mode == .recording ? Tokens.Color.textOnAccent : Tokens.Color.text)
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x2)
            .background(
                state.mode == .recording
                    ? Tokens.Color.record
                    : Tokens.Color.fillQuiet,
                in: Capsule()
            )
        }
        .buttonStyle(Pressable(scale: 0.96))
        .help(state.mode == .recording ? "Stop recording" : "Start recording")
    }
}
