import SwiftUI

/// Add / edit a dictionary entry. Supports both kinds (term, correction) with
/// live conflict warnings. Rendered as an Aurora sheet.
struct DictEditor: View {
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
            Text(isNew ? "New dictionary entry" : "Edit entry")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)

            Picker("", selection: $kind) {
                Text("Word / phrase").tag(DictEntryKind.term)
                Text("Correction").tag(DictEntryKind.correction)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: kind) { _, _ in validate() }

            VStack(spacing: Tokens.Space.x3) {
                if kind == .correction {
                    field("When you hear", text: $phrase, placeholder: "cloud code")
                    field("Write instead", text: $replacement, placeholder: "Claude Code")
                } else {
                    field("Word or phrase", text: $phrase, placeholder: "Anthropic")
                }
                field("Note (optional)", text: $note, placeholder: "who or what this is")
            }

            if !localWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(localWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Tokens.Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Color.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Tokens.Space.x6)
        .frame(width: 440)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .onAppear { validate() }
        .onChange(of: phrase) { _, _ in validate() }
        .onChange(of: replacement) { _, _ in validate() }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 9)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
        }
    }

    private var isNew: Bool { !dict.entries.contains { $0.id == entry.id } }

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
