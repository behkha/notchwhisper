import SwiftUI

/// One transcript row. The parent wraps it in a glass card, so this only lays
/// out content: the corrected text, timestamp, a copy affordance, and (when a
/// dictionary fix or LLM pass fired) small chips revealing what happened.
struct TranscriptRow: View {
    let rec: TranscriptRecord
    let copied: Bool
    var copyAction: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                Text(rec.finalText.isEmpty ? "(empty)" : rec.finalText)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: Tokens.Space.x2) {
                    Text(rec.createdAt, format: .relative(presentation: .named))
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                    if rec.corrected {
                        Chip(text: "\(rec.corrections.count) fix\(rec.corrections.count == 1 ? "" : "es")",
                             systemImage: "wand.and.sparkles", tint: Tokens.Color.accent)
                    }
                    if let mode = rec.llmMode, mode != .original {
                        Chip(text: mode.displayName, systemImage: mode.symbolName,
                             tint: Tokens.Color.success, filled: false)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(copied ? Tokens.Color.success : Tokens.Color.textSec)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Tokens.Color.fillQuiet).opacity(hover || copied ? 1 : 0))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy transcript")
    }
}

/// One dictionary row. Parent wraps it in a card.
struct DictRow: View {
    let entry: DictEntry
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    var body: some View {
        let _ = theme.theme
        HStack(spacing: Tokens.Space.x3) {
            IconTile(entry.kind == .term ? "text.badge.star" : "arrow.left.arrow.right",
                     tint: entry.kind == .term ? Tokens.Color.textSec : Tokens.Color.accent, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                if entry.kind == .correction {
                    (Text(entry.phrase).foregroundStyle(Tokens.Color.textSec)
                     + Text("  →  ").foregroundStyle(Tokens.Color.textTert)
                     + Text(entry.replacement).foregroundStyle(Tokens.Color.text))
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
            Text(entry.kind == .term ? "TERM" : "FIX")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-press to edit")
    }
}
