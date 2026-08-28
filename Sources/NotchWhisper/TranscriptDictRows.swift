import SwiftUI

/// One transcript row: shows the (corrected) text, when it was captured, and a
/// copy affordance. If a dictionary correction fired, a small badge reveals
/// what changed so the user can see the dictionary is doing something.
struct TranscriptRow: View {
    let rec: TranscriptRecord
    let copied: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    Text(rec.finalText.isEmpty ? "(empty)" : rec.finalText)
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if rec.corrected {
                        correctionsLine
                    }
                }
                Spacer(minLength: Tokens.Space.x2)
                VStack(alignment: .trailing, spacing: Tokens.Space.x1) {
                    Text(rec.createdAt, style: .time)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                    copyButton
                }
            }
        }
        .padding(Tokens.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(hover ? Tokens.Color.fillQuiet : Color.clear)
        )
        .onHover { hover = $0 }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rec.finalText, forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13))
                .foregroundStyle(copied ? Tokens.Color.success : Tokens.Color.textSec)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private var correctionsLine: some View {
        HStack(spacing: Tokens.Space.x1) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Color.accent)
            Text(correctionSummary)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var correctionSummary: String {
        let parts = rec.corrections.map { "“\($0.heard)” → “\($0.wrote)”" }
        return "Dictionary: " + parts.joined(separator: ", ")
    }
}

/// One dictionary row. Shows the phrase, the kind, and (for corrections) the
/// heard → wrote mapping. Tap to edit, secondary click to delete.
struct DictRow: View {
    let entry: DictEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            kindBadge
            VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                if entry.kind == .correction {
                    (Text(entry.phrase).font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.text)
                     + Text("  →  ").foregroundStyle(Tokens.Color.textTert)
                     + Text(entry.replacement).font(Tokens.TypeScale.body).foregroundStyle(Tokens.Color.accent))
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
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Color.textTert)
                .opacity(hover ? 1 : 0)
        }
        .padding(Tokens.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(hover ? Tokens.Color.fillQuiet : Color.clear)
        )
        .onHover { hover = $0 }
    }

    private var kindBadge: some View {
        Text(entry.kind == .term ? "TERM" : "FIX")
            .font(Tokens.TypeScale.micro)
            .foregroundStyle(entry.kind == .term ? Tokens.Color.textSec : Tokens.Color.accent)
            .padding(.horizontal, Tokens.Space.x2)
            .padding(.vertical, Tokens.Space.x1)
            .background(
                Capsule().fill(entry.kind == .term
                               ? Tokens.Color.fillQuiet
                               : Tokens.Color.accent.opacity(0.14))
            )
    }
}
