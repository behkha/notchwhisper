import SwiftUI
import AppKit
import Carbon

// MARK: - Shortcuts settings section
//
// Settings → Shortcuts is a LIST. One shortcut types what you said, another
// cleans it up, another starts a live session — and every one of them can
// override the mode, the AI switch, the typing behaviour or the language,
// exactly like an app profile. Anything left on "Use global setting" inherits.

struct ShortcutsSection: View {
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var store = HotkeyBindingStore.shared
    @ObservedObject private var modes = CustomModeStore.shared

    @State private var editing: HotkeyBinding?
    @State private var toDelete: HotkeyBinding?
    /// Re-read on every appearance: the user may have granted the permission in
    /// System Settings while this window was open.
    @State private var hasPermission = HotkeyMonitor.hasPermission

    var body: some View {
        SettingsGroup(title: "Shortcuts", footnote: footnote) {
            if !hasPermission { permissionRow }

            // Deleted, disabled or never given a key — all three leave the user
            // with no way to dictate by keyboard, and all three have to say so.
            if store.primary == nil {
                SettingRow(icon: "keyboard", tint: Tokens.Color.warn,
                           title: "No shortcut set",
                           subtitle: store.bindings.isEmpty
                            ? "Nothing is listening for a key right now. The Record button in the app and the menu bar still work."
                            : "Every shortcut below is switched off or has no key, so nothing is listening. The Record button in the app and the menu bar still work.") {
                    Button("Add one") { editing = blank() }.primaryAction()
                }
            }

            if !store.bindings.isEmpty {
                ForEach(store.bindings) { binding in
                    BindingRow(
                        binding: binding,
                        summary: summary(for: binding),
                        warning: warning(for: binding),
                        toggle: { store.setEnabled(!binding.enabled, for: binding) },
                        edit: { editing = binding },
                        duplicate: { duplicate(binding) },
                        remove: { toDelete = binding }
                    )
                }
            }

            starterRow
        }
        .onAppear { hasPermission = HotkeyMonitor.hasPermission }
        .sheet(item: $editing) { binding in
            HotkeyBindingEditor(binding: binding)
                .environmentObject(settings)
        }
        .confirmationDialog("Delete this shortcut?",
                            isPresented: Binding(get: { toDelete != nil },
                                                 set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(toDelete?.name ?? "")", role: .destructive) {
                if let binding = toDelete { remove(binding) }
                toDelete = nil
            }
            Button("Cancel", role: .cancel) { toDelete = nil }
        } message: {
            Text("The key stops doing anything. Your other shortcuts are unaffected.")
        }
    }

    private var footnote: String {
        store.bindings.isEmpty
            ? "Add a shortcut and NotchWhisper listens for it anywhere on the Mac."
            : "Hold a hold-to-talk shortcut to record and release to insert; press a live-session shortcut once to start and again to stop. Only one recording runs at a time — the most specific shortcut that matches wins."
    }

    // MARK: Rows

    private var permissionRow: some View {
        SettingRow(icon: "exclamationmark.triangle.fill", tint: Tokens.Color.warn,
                   title: "Input Monitoring is off",
                   subtitle: "macOS is not letting NotchWhisper see the keyboard, so none of these shortcuts can fire.") {
            Button("Fix it") { AppDelegate.shared?.promptInputMonitoring() }
                .primaryAction()
        }
    }

    /// Starting points. These only PREFILL the editor — nothing is installed
    /// behind the user's back.
    private var starterRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack {
                Text("START FROM")
                    .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer()
                Button { editing = blank() } label: { Label("New shortcut", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
            }
            HStack(spacing: Tokens.Space.x2) {
                ForEach(HotkeyBinding.starters) { starter in
                    Button { start(from: starter) } label: {
                        Label(starter.name, systemImage: starter.symbolName)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textSec)
                            .padding(.horizontal, Tokens.Space.x3)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Tokens.Color.fillQuiet))
                            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(starter.hint)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }

    // MARK: Copy

    private func summary(for binding: HotkeyBinding) -> String {
        var parts = [effectiveActivationLabel(binding)]
        if let mode = binding.processingMode { parts.append(modes.label(for: mode)) }
        if let enabled = binding.llmEnabled { parts.append(enabled ? "AI on" : "AI off") }
        if let autoType = binding.autoType { parts.append(autoType ? "Types text" : "History only") }
        if let newline = binding.insertNewline { parts.append(newline ? "Adds newline" : "No newline") }
        if let language = binding.language {
            parts.append(language.isEmpty ? "Auto-detect" : LanguageChoice.label(for: language))
        }
        return parts.joined(separator: " · ")
    }

    /// The activation this binding will actually get, with the reason when the
    /// model forced it back to hold-to-talk.
    private func effectiveActivationLabel(_ binding: HotkeyBinding) -> String {
        guard binding.effectiveActivation == .toggleLive, !canStreamLive else {
            return binding.activation == nil
                ? "\(binding.effectiveActivation.label) — follows Live dictation"
                : binding.effectiveActivation.label
        }
        return "Hold to talk — \(ModelRegistry.shared.descriptor(for: settings.modelId).displayName) can't stream"
    }

    /// Mirrors `AppDelegate.canStreamLive` so the list reads correctly even
    /// before the delegate exists (SwiftUI previews, the settings window
    /// opening during launch).
    private var canStreamLive: Bool {
        AppDelegate.shared?.canStreamLive ?? !LlamaModelOption.isLlamaId(settings.modelId)
    }

    private func warning(for binding: HotkeyBinding) -> String? {
        if let dupe = store.duplicate(of: binding) {
            return "Same key as “\(dupe.name)”."
        }
        if let shadow = store.shadowWarning(for: binding) { return shadow }
        if let system = store.systemWarning(for: binding) {
            return "macOS usually owns \(system)."
        }
        return nil
    }

    // MARK: Actions

    private func blank() -> HotkeyBinding {
        HotkeyBinding(name: "", keyCode: 0, carbonModifiers: 0)
    }

    private func start(from starter: HotkeyBinding.Starter) {
        var binding = blank()
        binding.name = store.uniqueName(basedOn: starter.name)
        binding.activation = starter.activation
        binding.processingModeKey = starter.processingModeKey
        editing = binding
    }

    private func duplicate(_ binding: HotkeyBinding) {
        var copy = binding
        copy.id = UUID()
        copy.name = store.uniqueName(basedOn: binding.name)
        // Two bindings must never claim the same key — clear it so the editor
        // asks for a new one.
        copy.keyCode = 0
        copy.carbonModifiers = 0
        copy.createdAt = Date()
        copy.updatedAt = Date()
        editing = copy
    }

    private func remove(_ binding: HotkeyBinding) {
        store.remove(binding)
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }
}

// MARK: - One row

private struct BindingRow: View {
    let binding: HotkeyBinding
    let summary: String
    let warning: String?
    let toggle: () -> Void
    let edit: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            IconTile(binding.effectiveActivation.symbolName,
                     tint: binding.enabled ? Tokens.Color.accent : Tokens.Color.textTert)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(binding.name.isEmpty ? "Untitled shortcut" : binding.name)
                        .font(Tokens.TypeScale.body.weight(.medium))
                        .foregroundStyle(Tokens.Color.text)
                    if binding.keyCode == 0 {
                        Chip(text: "No key", tint: Tokens.Color.warn)
                    }
                    if !binding.enabled { Chip(text: "Off", tint: Tokens.Color.textTert) }
                }
                Text(summary)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Tokens.Space.x3)

            if binding.keyCode != 0 {
                Text(binding.display)
                    .font(Tokens.TypeScale.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(binding.enabled ? Tokens.Color.text : Tokens.Color.textTert)
                    .padding(.horizontal, Tokens.Space.x2)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Color.fillQuiet))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            }

            Toggle("", isOn: Binding(get: { binding.enabled }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)

            Menu {
                Button("Edit…") { edit() }
                Button("Duplicate") { duplicate() }
                Divider()
                Button("Delete", role: .destructive) { remove() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textSec)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
        .contentShape(Rectangle())
        .onTapGesture { edit() }
    }
}

// MARK: - Editor

struct HotkeyBindingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var store = HotkeyBindingStore.shared
    @ObservedObject private var modes = CustomModeStore.shared

    let binding: HotkeyBinding

    @State private var draft: HotkeyBinding
    @StateObject private var recorder = HotkeyRecorder()

    init(binding: HotkeyBinding) {
        self.binding = binding
        _draft = State(initialValue: binding)
    }

    private var isNew: Bool { store.binding(id: binding.id) == nil }

    /// An exact duplicate is the ONE conflict that blocks saving: two identical
    /// triggers can never be told apart, so one of them would be dead weight.
    private var duplicate: HotkeyBinding? {
        draft.keyCode == 0 ? nil : store.duplicate(of: draft)
    }

    private var canSave: Bool { draft.isComplete && draft.keyCode != 0 && duplicate == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New shortcut" : "Edit shortcut")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.top, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                    LabeledField("Name", text: $draft.name, placeholder: "Clean prose")
                    triggerSection
                    activationSection
                    Divider().overlay(Tokens.Color.hairline)
                    overridesSection
                }
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)
            }
            .scrollIndicators(.never)

            Divider().overlay(Tokens.Color.hairline)

            HStack {
                // Why "Add shortcut" is dead. The shared button style does not
                // dim on `.disabled`, so the reason has to be written out.
                if let duplicate {
                    Label("“\(duplicate.name)” already uses this shortcut",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.danger)
                } else if draft.keyCode == 0 {
                    Label("Record a key combination first", systemImage: "keyboard")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                } else if !draft.isComplete {
                    Label("Give this shortcut a name", systemImage: "textformat")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add shortcut" : "Save") { save() }
                    .primaryAction()
                    .disabled(!canSave)
            }
            .padding(Tokens.Space.x6)
        }
        .frame(width: 560, height: 620)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
        .onAppear {
            recorder.onCommit = { code, mods in
                draft.keyCode = code
                draft.carbonModifiers = mods
            }
        }
        .onDisappear { recorder.cancel() }
    }

    // MARK: Trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcut").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            HStack(spacing: Tokens.Space.x3) {
                Button { recorder.toggle() } label: {
                    Text(recorder.capLabel(current: draft.keyCode == 0 ? "Set a shortcut" : draft.display))
                        .font(Tokens.TypeScale.title2)
                        .lineLimit(1)
                        .foregroundStyle(recorder.isRecording ? Tokens.Color.record : Tokens.Color.text)
                        .padding(.horizontal, Tokens.Space.x3)
                        .frame(minWidth: 150, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .fill(recorder.isRecording ? Tokens.Color.record.opacity(0.14) : Tokens.Color.fillQuiet))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(recorder.isRecording ? Tokens.Color.record.opacity(0.5) : Tokens.Color.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Text(recorder.isRecording
                     ? "Press a key or hold a modifier combination — Esc cancels"
                     : "Click the key cap, then press the key or combination you want")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ForEach(triggerWarnings, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Non-blocking warnings. A shadowed or system-owned shortcut is still
    /// saved — we cannot reliably enumerate what the system holds, and a
    /// warning beats a false refusal.
    private var triggerWarnings: [String] {
        guard draft.keyCode != 0 else { return [] }
        var lines: [String] = []
        if let shadow = store.shadowWarning(for: draft) { lines.append(shadow) }
        if let system = store.systemWarning(for: draft) {
            lines.append("macOS usually owns \(system). NotchWhisper only listens — the system keeps its own behaviour too.")
        }
        if !HotkeyMonitor.hasPermission {
            lines.append("Input Monitoring is off, so no shortcut can fire until it is granted in System Settings.")
        }
        return lines
    }

    // MARK: Activation

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What it does").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            Picker("", selection: $draft.activation) {
                Text("Follow the setting").tag(HotkeyBinding.Activation?.none)
                ForEach(HotkeyBinding.Activation.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(draft.activation?.blurb
                 ?? "Behaves the way the Live dictation setting says — \(draft.effectiveActivation.label.lowercased()) right now. Pick one of the others to pin this shortcut regardless of that setting.")
                .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
            if draft.effectiveActivation == .toggleLive, LlamaModelOption.isLlamaId(settings.modelId) {
                Label("\(ModelRegistry.shared.descriptor(for: settings.modelId).displayName) can't stream, so this shortcut runs as hold-to-talk until you switch to a Whisper model.",
                      systemImage: "info.circle")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Overrides

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("WHAT CHANGES WHEN YOU PRESS IT")
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)

            HotkeyOverridePicker(
                title: "Processing mode",
                globalLabel: modes.label(for: settings.processingMode),
                selectionLabel: draft.processingMode.map { modes.label(for: $0) },
                clear: { draft.processingMode = nil }
            ) {
                Button(ProcessingMode.offLabel) { draft.processingMode = .off }
                if !modes.modes.isEmpty {
                    Section("Your modes") {
                        ForEach(modes.modes) { mode in
                            Button(mode.name) { draft.processingMode = .custom(mode.id) }
                        }
                    }
                }
            }

            HotkeyOverrideSwitch(title: "AI processing",
                                 globalValue: settings.llmEnabled,
                                 value: $draft.llmEnabled)

            HotkeyOverrideSwitch(title: "Type into the app",
                                 globalValue: settings.autoTypeEnabled,
                                 value: $draft.autoType)

            HotkeyOverrideSwitch(title: "Newline after text",
                                 globalValue: settings.insertNewline,
                                 value: $draft.insertNewline)

            HotkeyOverridePicker(
                title: "Language",
                globalLabel: LanguageChoice.label(for: settings.language),
                selectionLabel: draft.language.map { LanguageChoice.label(for: $0) },
                clear: { draft.language = nil }
            ) {
                ForEach(LanguageChoice.all, id: \.code) { choice in
                    Button(choice.name) { draft.language = choice.code }
                }
            }

            Text("Anything left on “Use global setting” follows Settings. When an app profile and this shortcut disagree, the shortcut wins — pressing a specific key is the more explicit choice.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew { store.add(draft) } else { store.update(draft) }
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        dismiss()
    }
}

// MARK: - Override controls
//
// Same contract as the app-profile editor's: every override has a visible
// "Use global setting" state, because a nil that only shows as an unchecked box
// is indistinguishable from an explicit "off".

private struct HotkeyOverrideSwitch: View {
    let title: String
    let globalValue: Bool
    @Binding var value: Bool?

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            Text(title)
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)
            Spacer()
            Picker("", selection: Binding(
                get: { value.map { $0 ? Choice.on : .off } ?? .global },
                set: { choice in
                    switch choice {
                    case .global: value = nil
                    case .on:     value = true
                    case .off:    value = false
                    }
                }
            )) {
                Text(globalValue ? "Global (on)" : "Global (off)").tag(Choice.global)
                Text("On").tag(Choice.on)
                Text("Off").tag(Choice.off)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 230)
        }
    }

    private enum Choice: Hashable { case global, on, off }
}

private struct HotkeyOverridePicker<Options: View>: View {
    let title: String
    let globalLabel: String
    let selectionLabel: String?
    let clear: () -> Void
    @ViewBuilder var options: () -> Options

    var body: some View {
        HStack(spacing: Tokens.Space.x3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text)
                if selectionLabel == nil {
                    Text("Using global setting — \(globalLabel)")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
            Spacer()
            Menu {
                Button("Use global setting") { clear() }
                Divider()
                options()
            } label: {
                Text(selectionLabel ?? "Global").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 230)
        }
    }
}

// MARK: - Languages

/// The language codes Whisper accepts, as an offerable list. `""` is the
/// explicit "auto-detect" choice — distinct from nil, which means "inherit".
enum LanguageChoice {
    struct Choice: Hashable { let code: String; let name: String }

    static let all: [Choice] = [
        .init(code: "", name: "Auto-detect"),
        .init(code: "en", name: "English"),
        .init(code: "de", name: "German"),
        .init(code: "fr", name: "French"),
        .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "da", name: "Danish"),
        .init(code: "no", name: "Norwegian"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "pl", name: "Polish"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "ru", name: "Russian"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "fa", name: "Persian"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
    ]

    static func label(for code: String?) -> String {
        guard let code, !code.isEmpty else { return "Auto-detect" }
        return all.first { $0.code == code }?.name ?? code.uppercased()
    }
}
