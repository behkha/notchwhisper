import SwiftUI

/// Add / edit a dictionary entry. Supports both kinds:
///   - term:        a word/phrase to recognize.
///   - correction:  "heard" → "wrote".
/// Shows live warnings so the user sees conflicts before saving.
struct DictEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dict = DictionaryStore.shared

    let entry: DictEntry
    let onSave: (DictEntry) -> Void
    let onCancel: () -> Void

    @State private var kind: DictEntryKind
    @State private var phrase: String
    @State private var replacement: String
    @State private var note: String
    @State private var localWarnings: [String] = []

    init(entry: DictEntry, onSave: @escaping (DictEntry) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        _kind = State(initialValue: entry.kind)
        _phrase = State(initialValue: entry.phrase)
        _replacement = State(initialValue: entry.replacement)
        _note = State(initialValue: entry.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x4) {
            Text(isNew ? "Add Dictionary Entry" : "Edit Entry")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)

            Picker("Type", selection: $kind) {
                Text("Word / phrase").tag(DictEntryKind.term)
                Text("Correction").tag(DictEntryKind.correction)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in validate() }

            if kind == .correction {
                field("When you hear", text: $phrase, placeholder: "cloud code")
                field("Write instead", text: $replacement, placeholder: "Claude Code")
            } else {
                field("Word / phrase", text: $phrase, placeholder: "Anthropic")
            }

            field("Note (optional)", text: $note, placeholder: "who/what this is")

            if !localWarnings.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    ForEach(localWarnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: Tokens.Space.x2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Tokens.Color.warn).font(.system(size: 12))
                            Text(w).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Tokens.Space.x3)
                .background(Tokens.Color.warn.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(Pressable(scale: 0.97))
                    .foregroundStyle(Tokens.Color.textSec)
                    .padding(.trailing, Tokens.Space.x2)
                Button(action: save) {
                    Text("Save").font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.onAccent)
                        .padding(.horizontal, Tokens.Space.x4)
                        .padding(.vertical, Tokens.Space.x2)
                        .background(Tokens.Color.accent, in: Capsule())
                }
                .buttonStyle(Pressable())
                .disabled(!canSave)
            }
        }
        .padding(Tokens.Space.x6)
        .frame(width: 460)
        .background(Tokens.Color.bg)
        .onAppear { validate() }
        .onChange(of: phrase) { _, _ in validate() }
        .onChange(of: replacement) { _, _ in validate() }
    }

    private var isNew: Bool {
        !dict.entries.contains { $0.id == entry.id }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            Text(label).font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.textSec)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Tokens.TypeScale.body)
        }
    }

    private var canSave: Bool {
        let p = phrase.trimmingCharacters(in: .whitespaces)
        if kind == .correction {
            return !p.isEmpty && !replacement.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !p.isEmpty
    }

    private func validate() {
        var w: [String] = []
        let lc = phrase.lowercased()
        if kind == .correction {
            for part in lc.components(separatedBy: " ") where DictionaryStore.commonWords.contains(part) {
                w.append("“\(phrase)” contains the common word “\(part)” — it may correct ordinary text.")
            }
            if let last = lc.components(separatedBy: " ").last, DictionaryStore.commonWords.contains(last) {
                w.append("Ends in the common word “\(last)” — verify it won’t match real words.")
            }
        }
        localWarnings = w
    }

    private func save() {
        var updated = entry
        updated.kind = kind
        updated.phrase = phrase.trimmingCharacters(in: .whitespaces)
        updated.replacement = replacement.trimmingCharacters(in: .whitespaces)
        updated.note = note.trimmingCharacters(in: .whitespaces)
        updated.createdAt = isNew ? Date() : entry.createdAt
        onSave(updated)
    }
}
