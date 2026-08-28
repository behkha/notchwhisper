import SwiftUI

/// Models browser: a responsive grid of cards (req 6) that open a detail page
/// (req 7) with full accuracy/speed/language information so the user can pick
/// the right local Whisper model for their Mac and workload.
struct ModelsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @State private var selected: WhisperModelOption?

    var body: some View {
        if let model = selected {
            ModelDetailView(model: model, onBack: { selected = nil })
                .environmentObject(state)
                .environmentObject(settings)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: "cpu.fill").foregroundStyle(Tokens.Color.accent)
                    Text("Models")
                        .font(Tokens.TypeScale.largeTitle)
                        .foregroundStyle(Tokens.Color.text)
                    Spacer()
                    Text("Local · on-device · private")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                .padding(.horizontal, Tokens.Space.x4)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: Tokens.Space.x4)],
                    spacing: Tokens.Space.x4
                ) {
                    ForEach(WhisperModelOption.all) { m in
                        ModelCard(model: m, isActive: settings.modelId == m.id)
                            .onTapGesture { selected = m }
                    }
                }
                .padding(.horizontal, Tokens.Space.x4)
            }
            .padding(.vertical, Tokens.Space.x4)
        }
        .background(Tokens.Color.bg)
    }
}

/// A single model card in the grid: name, size, accuracy & speed at a glance.
struct ModelCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    let model: WhisperModelOption
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.display)
                            .font(Tokens.TypeScale.title2)
                            .foregroundStyle(Tokens.Color.text)
                        if isActive {
                            Text("ACTIVE")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.success)
                                .padding(.horizontal, Tokens.Space.x2)
                                .padding(.vertical, Tokens.Space.x1)
                                .background(Capsule().fill(Tokens.Color.success.opacity(0.16)))
                        }
                    }
                    Text(model.quality)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? Tokens.Color.success : Tokens.Color.textTert)
            }

            Text(model.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            // Decision tag (ChatGPT rec: lead with the verdict)
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.accent)
                Text(model.decision)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                Spacer(minLength: 0)
            }

            // Accuracy + speed bars
            MetricBar(label: "Accuracy", value: model.accuracyFraction,
                      display: "WER \(model.englishWER)", tone: .good)
            MetricBar(label: "Speed", value: model.speedFraction,
                      display: model.speedLabel, tone: .accent)

            // Two-axis Accuracy <-> Speed marker + time estimate (ChatGPT rec)
            AxisMarker(accuracy: model.accuracyFraction, speed: model.speedFraction)
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "timer")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.secPerMin)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }

            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.size).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Image(systemName: model.englishOnly ? "globe.americas" : "globe")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.lang)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .stroke(isActive ? Tokens.Color.accent.opacity(0.6) : Tokens.Color.separator,
                                lineWidth: isActive ? 1.5 : Tokens.Border.hair)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .scaleEffect(1.0)
        .animation(Tokens.Motion.hover, value: isActive)
    }
}

/// A labeled progress bar used on cards and the detail page.
struct MetricBar: View {
    let label: String
    let value: Double        // 0…1
    let display: String
    let tone: Tone

    enum Tone { case good, accent }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack {
                Text(label)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Text(display)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(Tokens.Color.fillQuiet)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fill)
                            .frame(width: max(6, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    }
            }
            .frame(height: 6)
        }
    }

    private var fill: SwiftUI.Color {
        switch tone {
        case .good:   return Tokens.Color.success
        case .accent: return Tokens.Color.accent
        }
    }
}

/// Two-axis Accuracy <-> Speed marker (ChatGPT rec): a single dot positioned by
/// speed (x, left=fast) and accuracy (y, top=accurate) is more intuitive than
/// two separate bars for non-technical users.
struct AxisMarker: View {
    let accuracy: Double   // 0…1, higher = more accurate
    let speed: Double       // 0…1, higher = faster

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            Text("Accuracy  ↔  Speed")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            GeometryReader { geo in
                let w = geo.size.width
                let h = max(34, geo.size.height)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Color.fillQuiet)
                    // faint diagonal hint: fast+accurate is top-right
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: CGPoint(x: w, y: 0))
                    }
                    .stroke(Tokens.Color.separator, lineWidth: 1)
                    .opacity(0.6)
                    Circle()
                        .fill(Tokens.Color.accent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Tokens.Color.surface, lineWidth: 2))
                        .position(
                            x: CGFloat(speed) * (w - 14) + 7,
                            y: (1 - CGFloat(accuracy)) * (h - 14) + 7
                        )
                        .animation(Tokens.Motion.meter, value: accuracy)
                        .animation(Tokens.Motion.meter, value: speed)
                }
                .frame(height: h)
            }
            .frame(height: 40)
            HStack {
                Text("Fast").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Text("Accurate").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
        }
    }
}

/// Full model detail page (req 7).
struct ModelDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    let model: WhisperModelOption
    let onBack: () -> Void

    private var isActive: Bool { settings.modelId == model.id }
    private var isLocal: Bool {
        (AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []).contains(model.folderName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                // Header
                HStack(spacing: Tokens.Space.x3) {
                    Button { onBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tokens.Color.accent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Tokens.Color.fillQuiet))
                    }
                    .buttonStyle(.plain)
                    .help("Back to Models")
                    VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                        HStack(spacing: Tokens.Space.x2) {
                            Text(model.display)
                                .font(Tokens.TypeScale.largeTitle)
                                .foregroundStyle(Tokens.Color.text)
                            if isActive {
                                Text("ACTIVE")
                                    .font(Tokens.TypeScale.micro)
                                    .foregroundStyle(Tokens.Color.success)
                                    .padding(.horizontal, Tokens.Space.x2)
                                    .padding(.vertical, Tokens.Space.x1)
                                    .background(Capsule().fill(Tokens.Color.success.opacity(0.16)))
                            }
                        }
                        Text(model.quality)
                            .font(Tokens.TypeScale.captionSB)
                            .foregroundStyle(Tokens.Color.accent)
                    }
                    Spacer(minLength: 0)
                    statusBadge
                }
                .padding(.horizontal, Tokens.Space.x4)

                Text(model.blurb)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Space.x4)

                // Big metrics
                HStack(spacing: Tokens.Space.x4) {
                    MetricBar(label: "Accuracy (English WER)", value: model.accuracyFraction,
                              display: model.englishWER, tone: .good)
                        .frame(maxWidth: .infinity)
                    MetricBar(label: "Speed", value: model.speedFraction,
                              display: model.speedLabel, tone: .accent)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Tokens.Space.x4)

                // Spec grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Tokens.Space.x4)],
                          spacing: Tokens.Space.x4) {
                    SpecTile(title: "Parameters", value: model.params)
                    SpecTile(title: "Download size", value: model.size)
                    SpecTile(title: "Runtime RAM", value: model.ram)
                    SpecTile(title: "English WER", value: model.englishWER)
                    SpecTile(title: "Multilingual WER", value: model.multiWER)
                    SpecTile(title: "Language", value: model.lang)
                }
                .padding(.horizontal, Tokens.Space.x4)

                // Recommendation
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    Label("When to use this model", systemImage: "lightbulb.fill")
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)
                    Text(model.recommendation.isEmpty ? "A good general-purpose choice." : model.recommendation)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Tokens.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                .padding(.horizontal, Tokens.Space.x4)

                // Action
                actionButton
                    .padding(.horizontal, Tokens.Space.x4)

                if state.isDownloading, settings.modelId == model.id {
                    ProgressView(value: state.downloadProgress) {
                        Text(state.downloadLabel).font(Tokens.TypeScale.caption)
                    }
                    .frame(width: 320)
                    .padding(.horizontal, Tokens.Space.x4)
                }
            }
            .padding(.vertical, Tokens.Space.x4)
        }
        .background(Tokens.Color.bg)
    }

    private var statusBadge: some View {
        Text(isLocal ? "Downloaded" : "Not downloaded")
            .font(Tokens.TypeScale.caption)
            .foregroundStyle(isLocal ? Tokens.Color.success : Tokens.Color.textTert)
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.vertical, Tokens.Space.x1)
            .background(Capsule().fill((isLocal ? Tokens.Color.success : Tokens.Color.textTert).opacity(0.14)))
    }

    private var actionButton: some View {
        Button {
            if isActive, isLocal {
                // already active + local: nothing to do
            } else if isLocal {
                settings.modelId = model.id
                NotificationCenter.default.post(name: .modelChanged, object: nil)
            } else {
                AppDelegate.shared?.requestDownload(modelId: model.id)
            }
        } label: {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: isActive && isLocal ? "checkmark.circle.fill"
                                : (isLocal ? "checkmark.circle" : "arrow.down.circle.fill"))
                Text(isActive && isLocal ? "Active"
                        : (isLocal ? "Use this model" : "Download & use"))
                    .font(Tokens.TypeScale.headline)
            }
            .foregroundStyle(isActive && isLocal ? Tokens.Color.success : Tokens.Color.textOnAccent)
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.vertical, Tokens.Space.x3)
            .frame(maxWidth: .infinity)
            .background(
                (isActive && isLocal ? Tokens.Color.success.opacity(0.16) : Tokens.Color.accent),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(state.isDownloading)
    }
}

/// A spec tile on the model detail page.
struct SpecTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            Text(title)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            Text(value)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }
}
