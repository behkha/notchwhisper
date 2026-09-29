import SwiftUI

/// One transcript row. The parent places it in a grouped list, so this only
/// lays out content: the corrected text, when it happened, a copy affordance
/// that appears on hover, and (when a dictionary fix or AI pass fired) quiet
/// chips revealing what happened.
struct TranscriptRow: View {
    enum TimeStyle { case relative, time, dateTime }

    let rec: TranscriptRecord
    let copied: Bool
    var timeStyle: TimeStyle = .relative
    var copyAction: (() -> Void)? = nil
    @ViewState private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rec.finalText.isEmpty ? "(empty)" : rec.finalText)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(rec.finalText.isEmpty ? Tokens.Color.textTert : Tokens.Color.text)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Group {
                        switch timeStyle {
                        case .relative: Text(rec.createdAt, format: .relative(presentation: .named))
                        case .time: Text(rec.createdAt, style: .time)
                        case .dateTime:
                            Text(rec.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .monospacedDigit()

                    if rec.corrected {
                        Chip(text: "\(rec.corrections.count) fix\(rec.corrections.count == 1 ? "" : "es")",
                             systemImage: "wand.and.sparkles", tint: Tokens.Color.accent)
                    }
                    if let mode = rec.modeLabel {
                        Chip(text: mode, systemImage: rec.modeSymbol,
                             tint: Tokens.Color.textSec, filled: false)
                    }
                    if let profile = rec.profileName {
                        Chip(text: profile, systemImage: "app.badge",
                             tint: Tokens.Color.textSec, filled: false)
                    }
                    if let strayed = rec.insertedIntoBundleID {
                        Chip(text: "Typed into \(AppCatalog.name(for: strayed))",
                             systemImage: "arrow.turn.down.right",
                             tint: Tokens.Color.warn)
                    }
                }
            }
            Spacer(minLength: Tokens.Space.x2)
            copyButton
        }
        .onHover { hover = $0 }
    }

    private var copyButton: some View {
        Button {
            if let copyAction { copyAction() } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rec.finalText, forType: .string)
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Tokens.Color.success : Tokens.Color.textSec)
                .frame(width: 28, height: 28)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .opacity(hover || copied ? 1 : 0.35)
        .animation(Tokens.Motion.hover, value: hover)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy transcript")
    }
}

/// One dictionary row. Parent places it in a grouped list.
struct DictRow: View {
    let entry: DictEntry
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    var body: some View {
        let _ = theme.theme
        HStack(spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 3) {
                if entry.kind == .correction {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(entry.phrase)
                            .foregroundStyle(Tokens.Color.textSec)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tokens.Color.accent)
                        Text(entry.replacement)
                            .foregroundStyle(Tokens.Color.text)
                    }
                    .font(Tokens.TypeScale.body)
                    .textSelection(.enabled)
                } else {
                    Text(entry.phrase)
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                        .textSelection(.enabled)
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
            Spacer(minLength: Tokens.Space.x2)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Tokens.Color.textQuat)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-press to edit")
    }
}
