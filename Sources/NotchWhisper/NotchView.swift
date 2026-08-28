import SwiftUI

/// The notch silhouette: flat top (flush with the screen's top edge) and
/// continuous rounded bottom corners — the same geometry Apple uses for the
/// hardware notch and the Dynamic Island. When it morphs larger, it reads as
/// the notch itself expanding downward.
struct IslandShape: InsettableShape {
    var radius: CGFloat = 22
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: 0
            ),
            style: .continuous
        ).path(in: r)
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// The island UI. A large transparent panel is anchored top-center on the
/// active display (NotchController); this view draws the black silhouette at
/// top-center inside it and morphs it between three sizes:
///
///  · compact — exactly the physical notch's size (invisible against it)
///  · active  — a wide rectangle expanding DOWN from the notch with the
///              record dot + live ribbon waveform + timer (recording), or a
///              spinner + stilled ribbon (transcribing)
///  · result  — a smaller pill with the done/error state
///
/// All size morphs run under the openMorph/closeMorph springs; the waveform
/// itself is model-driven at 60 Hz (no implicit animations on top of it).
struct NotchView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var waveform: WaveformModel
    @EnvironmentObject private var controller: NotchController

    private enum Phase { case compact, active, result }
    @State private var phase: Phase = .compact

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: state.mode == .idle)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                island(t: t)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .onAppear { sync(animated: false) }
        .onChange(of: state.mode) { _, _ in sync(animated: true) }
    }

    // MARK: - Phase

    private var isActive: Bool { state.mode == .recording || state.mode == .transcribing }
    private var isResult: Bool { state.mode == .done || state.mode == .error }

    private func sync(animated: Bool) {
        let target: Phase = isActive ? .active : (isResult ? .result : .compact)
        guard target != phase else { return }
        if animated {
            withAnimation(target == .compact ? Tokens.Motion.closeMorph : Tokens.Motion.openMorph) {
                phase = target
            }
        } else {
            phase = target
        }
    }

    private var targetSize: CGSize {
        switch phase {
        case .compact:
            return CGSize(width: controller.notchInfo.width,
                          height: controller.notchInfo.bandHeight)
        case .active:
            // The island grows DOWN from the notch. Content lives BELOW the
            // physical notch band (bandHeight), so the visualizer is never
            // clipped by the hardware cutout: band + 64pt visualizer + margin.
            return CGSize(width: 420,
                          height: controller.notchInfo.bandHeight + 78)
        case .result:
            return CGSize(width: 216,
                          height: controller.notchInfo.bandHeight + 40)
        }
    }

    private var targetRadius: CGFloat {
        switch phase {
        case .compact: return 16
        case .active:  return 26
        case .result:  return 22
        }
    }

    // MARK: - Island

    private func island(t: TimeInterval) -> some View {
        let size = targetSize
        let radius = targetRadius

        return ZStack {
            // Ambient halo: a blurred copy of the silhouette. While recording
            // it is VOICE-REACTIVE (when enabled in Settings): its color heats
            // from warm amber to coral and its opacity/radius breathe with the
            // smoothed mic energy — the island visibly listens. With the toggle
            // off it stays a calm, static warm glow. Other modes keep their
            // cool/semantic tints, Dynamic-Island style.
            IslandShape(radius: radius)
                .fill(haloFill)
                .blur(radius: haloBlur)
                .opacity(haloOpacity)
                .padding(-12)

            // The solid black silhouette — the UI itself.
            IslandShape(radius: radius)
                .fill(.black)
                .overlay(
                    IslandShape(radius: radius)
                        .strokeBorder(.white.opacity(phase == .compact ? 0 : 0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .overlay(
                    content(t: t)
                        // Keep every mode's content BELOW the physical notch
                        // band — the top bandHeight pts of the island sit
                        // inside the hardware cutout and are not visible.
                        .padding(.top, controller.notchInfo.bandHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .opacity(phase == .compact ? 0 : 1)
                        .scaleEffect(phase == .compact ? 0.7 : 1)
                )
        }
        .frame(width: size.width, height: size.height)
    }

    /// Halo color by mode. Recording honors the voice-reactive toggle:
    /// on → heats amber→coral with the smoothed glow energy; off → static amber.
    private var haloFill: LinearGradient {
        switch state.mode {
        case .recording:
            let c = settings.reactiveGlow
                ? Tokens.glow(for: waveform.frame.glow)
                : Tokens.Color.glowQuiet
            return LinearGradient(
                colors: [c, c.opacity(0.72)],
                startPoint: .leading, endPoint: .trailing
            )
        case .transcribing:
            return LinearGradient(
                colors: [.white.opacity(0.9), SwiftUI.Color(red: 0.6, green: 0.82, blue: 1.0)],
                startPoint: .leading, endPoint: .trailing
            )
        case .done:
            return LinearGradient(
                colors: [Tokens.Color.success.opacity(0.9), Tokens.Color.success.opacity(0.6)],
                startPoint: .leading, endPoint: .trailing
            )
        case .error:
            return LinearGradient(
                colors: [Tokens.Color.danger.opacity(0.9), Tokens.Color.danger.opacity(0.6)],
                startPoint: .leading, endPoint: .trailing
            )
        case .idle:
            return LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Halo blur breathes with the voice when reactive (wider bloom when loud).
    private var haloBlur: CGFloat {
        if state.mode == .recording && settings.reactiveGlow {
            return 20 + 14 * waveform.frame.glow
        }
        return 22
    }

    private var haloOpacity: Double {
        switch state.mode {
        case .recording:
            // Reactive: the glow swells with the voice. Static: a fixed ember.
            return settings.reactiveGlow
                ? 0.34 + 0.50 * Double(waveform.frame.glow)
                : 0.38
        case .transcribing: return 0.22
        case .done:         return 0.20
        case .error:        return 0.24
        case .idle:         return 0
        }
    }

    // MARK: - Content by mode

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        switch state.mode {
        case .recording:
            HStack(spacing: 10) {
                Circle()
                    .fill(Tokens.Color.record)
                    .frame(width: 7, height: 7)
                    .scaleEffect(1.0 + 0.25 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.2)))
                    .shadow(color: Tokens.Color.record.opacity(0.6), radius: 4)
                AudioVisualizer(
                    style: settings.visualizerStyle,
                    state: .speaking,
                    heights: waveform.frame.heights,
                    energy: waveform.frame.energy,
                    tint: settings.reactiveGlow
                        ? Tokens.glowRGB(for: waveform.frame.glow)
                        : nil,
                    t: t
                )
                .frame(height: 64)
                Text(elapsed)
                    .font(Tokens.TypeScale.micro.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.9))
                    .frame(width: 14, height: 14)
                AudioVisualizer(
                    style: settings.visualizerStyle,
                    state: .thinking,
                    heights: waveform.frame.heights,
                    energy: waveform.frame.energy,
                    tint: nil,
                    t: t
                )
                .frame(height: 64)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .done:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Color.success)
                Text("Done")
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error:
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Color.danger)
                Text(state.statusMessage.isEmpty ? "Error" : state.statusMessage)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .idle:
            EmptyView()
        }
    }

    private var elapsed: String {
        guard let start = state.recordingStart else { return "0:00" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - The bar waveform

/// A horizontal row of 32 FIXED capsule bars — a spectrum analyzer. Bar *i*
/// shows the energy of frequency band *i* (low pitches on the left, high
/// pitches on the right). Bars NEVER move horizontally and never swap places;
/// each one only changes height, mirrored around the center line. Fast attack
/// / smooth release comes from the model, so bars jump when you speak and
/// settle gently when you stop. Talking in a high pitch visibly lifts the
/// right-hand bars; a low voice lifts the left-hand bars.
///
/// Voice-reactive color (when `tint` is provided, i.e. the Settings toggle is
/// on): each bar blends from white toward the glow color in proportion to its
/// own height × the overall loudness — quiet bars stay white, loud bars burn
/// amber→red. With `tint == nil` the bars stay a calm, static white.
///
/// A soft bloom of the tint color sits behind the bars and swells with
/// loudness. End bars fade in opacity so the row dissolves into the island.
struct BarWaveform: View {
    let heights: [CGFloat]
    let energy: CGFloat
    /// Voice-reactive tint (glow color for current loudness). nil = static white.
    let tint: (r: Double, g: Double, b: Double)?

    private let barWidth: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let barCount = heights.count
            guard barCount > 1 else { return }
            let midY = size.height * 0.5
            let maxHalf = size.height * 0.46
            let gap = (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

            // Precompute bar rects + per-bar colors. Bar i == band i: fixed
            // position, only the height changes.
            var rects: [CGRect] = []
            var colors: [SwiftUI.Color] = []
            rects.reserveCapacity(barCount)
            colors.reserveCapacity(barCount)
            for i in 0..<barCount {
                let h = heights[i]
                let halfH = max(2.0, h * maxHalf)
                let x = CGFloat(i) * (barWidth + gap)
                rects.append(CGRect(x: x, y: midY - halfH, width: barWidth, height: halfH * 2))

                // End fade: dissolve the outermost bars into the island.
                let edge = min(CGFloat(i), CGFloat(barCount - 1 - i))
                let fade = min(1, 0.35 + edge * 0.22)

                if let tint {
                    // Whiter when small/quiet, hotter when tall/loud.
                    let mix = Double(min(1, h * (0.45 + 0.75 * energy)))
                    let r = 1.0 + (tint.r - 1.0) * mix
                    let g = 1.0 + (tint.g - 1.0) * mix
                    let b = 1.0 + (tint.b - 1.0) * mix
                    colors.append(SwiftUI.Color(red: r, green: g, blue: b).opacity(0.95 * fade))
                } else {
                    colors.append(.white.opacity(0.92 * fade))
                }
            }

            // 1. Bloom — soft colored light behind the bars, swells with voice.
            var bloom = context
            bloom.addFilter(.blur(radius: 6))
            let bloomColor: SwiftUI.Color = tint.map {
                SwiftUI.Color(red: $0.r, green: $0.g, blue: $0.b).opacity(0.16 + 0.30 * Double(energy))
            } ?? .white.opacity(0.10 + 0.12 * Double(energy))
            for rect in rects {
                bloom.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(bloomColor))
            }

            // 2. The bars themselves.
            for (i, rect) in rects.enumerated() {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(colors[i])
                )
            }
        }
        .drawingGroup()
        .animation(nil, value: heights)
    }
}
