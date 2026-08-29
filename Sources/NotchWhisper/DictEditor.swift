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
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "Add Dictionary Entry" : "Edit Entry") {
                    Picker("Type", selection: $kind) {
                        Text("Word / phrase").tag(DictEntryKind.term)
                        Text("Correction").tag(DictEntryKind.correction)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, _ in validate() }

                    if kind == .correction {
                        TextField("When you hear", text: $phrase, prompt: Text("cloud code"))
                        TextField("Write instead", text: $replacement, prompt: Text("Claude Code"))
                    } else {
                        TextField("Word / phrase", text: $phrase, prompt: Text("Anthropic"))
                    }

                    TextField("Note (optional)", text: $note, prompt: Text("who/what this is"))
                }

                if !localWarnings.isEmpty {
                    Section {
                        ForEach(localWarnings, id: \.self) { w in
                            Label {
                                Text(w).font(Tokens.TypeScale.caption)
                                    .foregroundStyle(Tokens.Color.textSec)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Tokens.Color.warn)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // Let the sheet's glass surface show through.
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.vertical, Tokens.Space.x4)
        }
        .frame(width: 460)
        .onAppear { validate() }
        .onChange(of: phrase) { _, _ in validate() }
        .onChange(of: replacement) { _, _ in validate() }
    }

    private var isNew: Bool {
        !dict.entries.contains { $0.id == entry.id }
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
