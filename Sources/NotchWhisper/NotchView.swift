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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: state.mode == .idle && !isBootLoading)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                island(t: t)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .onAppear { sync(animated: false) }
        .onChange(of: state.mode) { _, _ in sync(animated: true) }
        .onChange(of: isBootLoading) { _, _ in sync(animated: true) }
    }

    /// Idle, but a model download or load is running — show a progress pill.
    private var isBootLoading: Bool {
        state.mode == .idle && (state.isDownloading || state.isLoadingModel)
    }

    // MARK: - Phase

    // `.improving` (local LLM post-processing) belongs here too: the island
    // must stay expanded through the whole Transcribing… → Improving… → Done
    // sequence, otherwise the notch collapses while the LLM is processing.
    private var isActive: Bool {
        state.mode == .recording || state.mode == .transcribing
            || state.mode == .dictating || state.mode == .improving
    }
    private var isResult: Bool { state.mode == .done || state.mode == .error }

    private func sync(animated: Bool) {
        let target: Phase = (isActive || isBootLoading) ? .active : (isResult ? .result : .compact)
        guard target != phase else { return }
        if animated {
            // Respect Reduce Motion: same completion, no spring travel — a
            // quick cross-fade communicates the state change without movement.
            let rm = Tokens.A11y.reduceMotion
            withAnimation(target == .compact ? Tokens.Motion.closeMorph(reduceMotion: rm)
                                              : Tokens.Motion.openMorph(reduceMotion: rm)) {
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
            // Errors carry a real message and need room to breathe; "Done" is
            // a single word and stays compact.
            return state.mode == .error
                ? CGSize(width: 360, height: controller.notchInfo.bandHeight + 56)
                : CGSize(width: 200, height: controller.notchInfo.bandHeight + 40)
        }
    }

    private var targetRadius: CGFloat {
        switch phase {
        case .compact: return 16
        case .active:  return 30
        case .result:  return 24
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

            // The silhouette — the UI itself. A near-black vertical gradient
            // (not flat) with a soft top light-catch reads as a physical,
            // glassy object rather than a sticker.
            IslandShape(radius: radius)
                .fill(
                    LinearGradient(
                        colors: [SwiftUI.Color(red: 0.07, green: 0.07, blue: 0.09), .black],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    IslandShape(radius: radius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(phase == .compact ? 0 : 0.18), .white.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
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
        // macOS 26 Liquid Glass: the island picks up the system's refractive
        // depth. The black silhouette underneath keeps the compact phase
        // invisible against the physical notch; older releases skip this.
        .glassIsland(in: IslandShape(radius: radius))
        // VoiceOver: the island is purely visual status — expose one concise,
        // current summary instead of its raw contents.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(islandA11yLabel)
    }

    /// A spoken summary of the island's current state for VoiceOver.
    private var islandA11yLabel: String {
        if isBootLoading {
            return state.isDownloading
                ? "Downloading model, \(Int((state.displayProgress * 100).rounded())) percent"
                : "Loading model, \(Int((state.modelLoadProgress * 100).rounded())) percent"
        }
        switch state.mode {
        case .recording:
            return "Recording, \(elapsed)"
        case .dictating:
            return "Dictating, \(elapsed)"
        case .transcribing:
            return "Transcribing"
        case .improving:
            return "Improving transcription"
        case .done:
            return "Transcription done"
        case .error:
            return "Error: \(state.statusMessage.isEmpty ? "unknown" : state.statusMessage)"
        case .idle:
            return ""
        }
    }

    /// Halo color by mode. Recording honors the voice-reactive toggle:
    /// on → heats amber→coral with the smoothed glow energy; off → static amber.
    private var haloFill: LinearGradient {
        switch state.mode {
        case .recording, .dictating:
            let c = settings.reactiveGlow
                ? Tokens.glow(for: waveform.frame.glow)
                : Tokens.Color.glowQuiet
            return LinearGradient(
                colors: [c, c.opacity(0.72)],
                startPoint: .leading, endPoint: .trailing
            )
        case .transcribing, .improving:
            return LinearGradient(
                colors: [.white.opacity(0.9), SwiftUI.Color(red: 0.6, green: 0.82, blue: 1.0)],
                startPoint: .leading, endPoint: .trailing
            )
        case .idle where isBootLoading:
            let c = Tokens.Color.accent
            return LinearGradient(colors: [c.opacity(0.8), c.opacity(0.5)],
                                  startPoint: .leading, endPoint: .trailing)
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
    /// Reduce Motion: fixed, calm radius.
    private var haloBlur: CGFloat {
        if (state.mode == .recording || state.mode == .dictating) && settings.reactiveGlow && !Tokens.A11y.reduceMotion {
            return 20 + 14 * waveform.frame.glow
        }
        return 22
    }

    private var haloOpacity: Double {
        switch state.mode {
        case .recording, .dictating:
            // Reactive: the glow swells with the voice. Static: a fixed ember.
            // Reduce Motion keeps the calm, static ember.
            return settings.reactiveGlow && !Tokens.A11y.reduceMotion
                ? 0.34 + 0.50 * Double(waveform.frame.glow)
                : 0.38
        case .transcribing, .improving: return 0.22
        case .done:         return 0.20
        case .error:        return 0.24
        case .idle:         return isBootLoading ? 0.22 : 0
        }
    }

    /// Decorative pulse scale for the recording dot. Collapses to 1.0 (steady)
    /// under Reduce Motion to avoid unnecessary movement.
    private func recordDotScale(t: TimeInterval) -> CGFloat {
        if Tokens.A11y.reduceMotion { return 1.0 }
        return 1.0 + 0.25 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.2))
    }

    // MARK: - Content by mode

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        if isBootLoading {
            bootLoadingContent
        } else {
            modeContent(t: t)
        }
    }

    /// Notch content while a model downloads / loads at idle (req 3).
    private var bootLoadingContent: some View {
        let downloading = state.isDownloading
        let pct = downloading
            ? Int((state.displayProgress * 100).rounded())
            : Int((state.modelLoadProgress * 100).rounded())
        let label = downloading
            ? (state.downloadLabel.isEmpty ? "Downloading model…" : state.downloadLabel)
            : (state.modelLoadPhase.isEmpty ? "Loading model…" : state.modelLoadPhase)
        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: downloading ? "arrow.down.circle" : "gearshape.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(label)
                    .font(Tokens.TypeScale.notchLabel)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(pct)%")
                    .font(Tokens.TypeScale.notchLabel.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            GeometryReader { g in
                let p = downloading ? max(state.displayProgress, 0.01) : max(state.modelLoadProgress, 0.02)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(Tokens.Color.accentGradient)
                        .frame(width: max(4, g.size.width * p))
                }
            }
            .frame(height: 4)
            .animation(Tokens.Motion.ease, value: state.modelLoadProgress)
            .animation(Tokens.Motion.ease, value: state.displayProgress)
            if downloading, !state.downloadDetailText.isEmpty {
                Text(state.downloadDetailText)
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func modeContent(t: TimeInterval) -> some View {
        switch state.mode {
        case .recording:
            HStack(spacing: 10) {
                Circle()
                    .fill(Tokens.Color.record)
                    .frame(width: 7, height: 7)
                    // Decorative pulse — collapses to a steady dot under
                    // Reduce Motion.
                    .scaleEffect(recordDotScale(t: t))
                    .shadow(color: Tokens.Color.record.opacity(0.6), radius: 4)
                sessionChip
                AudioVisualizer(
                    style: settings.visualizerStyle,
                    state: .speaking,
                    heights: waveform.frame.heights,
                    energy: waveform.frame.energy,
                    tint: settings.reactiveGlow && !Tokens.A11y.reduceMotion
                        ? Tokens.glowRGB(for: waveform.frame.glow)
                        : nil,
                    t: t
                )
                .frame(height: 64)
                Text(elapsed)
                    .font(Tokens.TypeScale.notchLabel.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .dictating:
            // Same active island as recording, plus a live transcript line that
            // shows what is being recognized + typed right now (truncated to
            // the middle dynamic-island style — the newest words stay visible).
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Tokens.Color.record)
                        .frame(width: 7, height: 7)
                        .scaleEffect(recordDotScale(t: t))
                        .shadow(color: Tokens.Color.record.opacity(0.6), radius: 4)
                    sessionChip
                    Text(state.partialText.isEmpty ? "Listening…" : state.partialText)
                        .font(Tokens.TypeScale.notchLabel)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(elapsed)
                        .font(Tokens.TypeScale.notchLabel.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                AudioVisualizer(
                    style: settings.visualizerStyle,
                    state: .speaking,
                    heights: waveform.frame.heights,
                    energy: waveform.frame.energy,
                    tint: settings.reactiveGlow && !Tokens.A11y.reduceMotion
                        ? Tokens.glowRGB(for: waveform.frame.glow)
                        : nil,
                    t: t
                )
                .frame(height: 34)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .transcribing, .improving:
            // The label makes transcription and LLM post-processing read as one
            // continuous action: Transcribing… → Improving… → Done.
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.9))
                    .frame(width: 14, height: 14)
                Text(state.mode == .improving
                     ? (state.statusMessage.isEmpty ? "Improving…" : state.statusMessage)
                     : "Transcribing…")
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
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
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Color.danger)
                Text(state.statusMessage.isEmpty ? "Error" : state.statusMessage)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .idle:
            EmptyView()
        }
    }

    /// "Slack · Clean prose" — which app profile and which hotkey binding are
    /// shaping this dictation. Silent when neither had an opinion, so the
    /// common case is exactly the island it has always been.
    @ViewBuilder
    private var sessionChip: some View {
        if !state.sessionLabel.isEmpty {
            Text(state.sessionLabel)
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.12)))
                .fixedSize()
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
