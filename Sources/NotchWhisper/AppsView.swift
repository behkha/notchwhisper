import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Apps page
//
// App profiles: "when I dictate into Slack, write it like a Slack message".
// Every override is optional, so a profile changes exactly what the user asked
// it to change and inherits the rest from Settings.

struct AppsView: View {
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var store = AppProfileStore.shared
    @ObservedObject private var modes = CustomModeStore.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @State private var editing: AppProfile?
    @State private var toDelete: AppProfile?

    var body: some View {
        let _ = theme.theme
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                SectionHeader("Apps", eyebrow: eyebrow,
                              subtitle: "Give an app its own dictation behaviour. Anything you don't set here keeps using your global settings.") {
                    Button { newProfile() } label: { Label("New profile", systemImage: "plus") }
                        .primaryAction()
                }

                if store.profiles.isEmpty {
                    EmptyStateView(
                        icon: "app.badge",
                        title: "Same settings everywhere",
                        message: "NotchWhisper writes the same way in every app right now. Add a profile to change the mode, the AI connection or the typing behaviour for one app.",
                        actionTitle: "Add your first profile",
                        action: { newProfile() }
                    )
                    .frame(height: 300)
                    .card(padding: nil)
                } else {
                    VStack(spacing: Tokens.Space.x3) {
                        ForEach(store.profiles) { profile in
                            ProfileCard(
                                profile: profile,
                                summary: summary(for: profile),
                                toggle: { store.setEnabled(!profile.enabled, for: profile) },
                                edit: { editing = profile },
                                duplicate: { duplicate(profile) },
                                remove: { toDelete = profile }
                            )
                        }
                    }
                }

                suggestionsRow
                footnote
            }
            .padding(Tokens.Space.x8)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(item: $editing) { profile in
            AppProfileEditor(profile: profile)
        }
        .confirmationDialog("Delete this profile?",
                            isPresented: Binding(get: { toDelete != nil },
                                                 set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(toDelete?.name ?? "")", role: .destructive) {
                if let p = toDelete { store.remove(p) }
                toDelete = nil
            }
            Button("Cancel", role: .cancel) { toDelete = nil }
        } message: {
            Text("Dictation in those apps goes back to your global settings.")
        }
    }

    private var eyebrow: String {
        let n = store.profiles.count
        return n == 0 ? "No profiles yet" : "\(n) profile\(n == 1 ? "" : "s") · \(store.enabledCount) active"
    }

    private func summary(for profile: AppProfile) -> String {
        var parts: [String] = []
        if profile.targetsCLI { parts.append(profile.tools.joined(separator: ", ")) }
        if let mode = profile.processingMode { parts.append(modes.label(for: mode)) }
        if let enabled = profile.llmEnabled { parts.append(enabled ? "AI on" : "AI off") }
        if let id = profile.connectionID,
           let connection = LLMConnectionStore.shared.connection(id: id) {
            parts.append(connection.name)
        } else if profile.connectionID != nil {
            parts.append("Missing connection")
        }
        if let autoType = profile.autoType { parts.append(autoType ? "Types text" : "History only") }
        if let newline = profile.insertNewline { parts.append(newline ? "Adds newline" : "No newline") }
        if let mode = profile.insertionMode { parts.append(mode.label) }
        if let id = profile.modelId {
            parts.append(ModelRegistry.shared.descriptor(for: id).displayName)
        }
        return parts.isEmpty ? "No overrides yet — this profile changes nothing." : parts.joined(separator: " · ")
    }

    private var suggestionsRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("START FROM AN APP")
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Tokens.Space.x2)],
                      alignment: .leading, spacing: Tokens.Space.x2) {
                ForEach(AppProfile.suggestions) { suggestion in
                    Button { start(from: suggestion) } label: {
                        Label(suggestion.name, systemImage: suggestion.symbolName)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textSec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Space.x3)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Tokens.Color.fillQuiet))
                            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footnote: some View {
        Text("The profile is chosen when you press the hotkey, from whichever app is in front. Browsers count as one app — a profile for Chrome applies to every site. NotchWhisper's own windows never match a profile.")
            .font(Tokens.TypeScale.caption)
            .foregroundStyle(Tokens.Color.textTert)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Tokens.Space.x2)
    }

    // MARK: Actions

    private func newProfile() {
        editing = AppProfile(name: "", bundleIDs: [])
    }

    /// A suggestion prefills the editor with only the apps the user actually
    /// has installed — offering a profile for an app that isn't there is noise.
    private func start(from suggestion: AppProfile.Suggestion) {
        let installed = suggestion.bundleIDs.filter { AppCatalog.isInstalled($0) }
        editing = AppProfile(
            name: store.uniqueName(basedOn: suggestion.name),
            bundleIDs: installed.isEmpty ? suggestion.bundleIDs : installed,
            cliTools: suggestion.cliTools,
            symbolName: suggestion.symbolName
        )
    }

    private func duplicate(_ profile: AppProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = store.uniqueName(basedOn: profile.name)
        // Two profiles must never claim the same app.
        copy.bundleIDs = []
        copy.createdAt = Date()
        copy.updatedAt = Date()
        editing = copy
    }
}

// MARK: - Profile card

private struct ProfileCard: View {
    let profile: AppProfile
    let summary: String
    let toggle: () -> Void
    let edit: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            IconTile(profile.symbolName,
                     tint: profile.enabled ? Tokens.Color.accent : Tokens.Color.textTert, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(profile.name.isEmpty ? "Untitled profile" : profile.name)
                        .font(Tokens.TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Color.text)
                    if !profile.enabled { Chip(text: "Off", tint: Tokens.Color.textTert) }
                    if profile.bundleIDs.isEmpty {
                        Chip(text: "No apps", tint: Tokens.Color.warn)
                    }
                    if profile.targetsCLI {
                        Chip(text: "Command line", systemImage: "terminal",
                             tint: Tokens.Color.accent, filled: false)
                    }
                }
                Text(summary)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                appRow
            }

            Spacer(minLength: Tokens.Space.x3)

            HStack(spacing: Tokens.Space.x2) {
                Toggle("", isOn: Binding(get: { profile.enabled }, set: { _ in toggle() }))
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
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
        }
        .padding(Tokens.Space.x4)
        .card(radius: Tokens.Radius.md, padding: nil, elevated: false)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
            .strokeBorder(profile.enabled ? Tokens.Color.accent.opacity(0.28) : .clear, lineWidth: 1))
        .opacity(profile.enabled ? 1 : 0.7)
        .onHover { hover = $0 }
        .hoverLift(hover)
        .onTapGesture { edit() }
    }

    private var appRow: some View {
        HStack(spacing: Tokens.Space.x2) {
            ForEach(profile.bundleIDs.prefix(6), id: \.self) { bundleID in
                if let icon = AppCatalog.icon(for: bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 12)).foregroundStyle(Tokens.Color.textTert)
                }
            }
            if profile.bundleIDs.count > 6 {
                Text("+\(profile.bundleIDs.count - 6)")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Editor

struct AppProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AppProfileStore.shared
    @ObservedObject private var modes = CustomModeStore.shared
    @ObservedObject private var connections = LLMConnectionStore.shared
    @EnvironmentObject private var settings: Settings

    let profile: AppProfile

    @State private var draft: AppProfile
    @State private var newTool = ""

    init(profile: AppProfile) {
        self.profile = profile
        _draft = State(initialValue: profile)
    }

    private var isNew: Bool { store.profile(id: profile.id) == nil }

    private var conflict: (bundleID: String, owner: AppProfile)? {
        for bundleID in draft.bundleIDs {
            if let owner = store.profileClaiming(bundleID, excluding: draft.id) {
                return (bundleID, owner)
            }
        }
        return nil
    }

    private var canSave: Bool { draft.isComplete && conflict == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New app profile" : "Edit app profile")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.top, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                    LabeledField("Name", text: $draft.name, placeholder: "Slack")
                    iconPicker
                    appsSection
                    if claimsTerminal { cliToolsSection }
                    Divider().overlay(Tokens.Color.hairline)
                    overridesSection
                }
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)
            }
            .scrollIndicators(.never)

            Divider().overlay(Tokens.Color.hairline)

            HStack {
                if let conflict {
                    Label("\(AppCatalog.name(for: conflict.bundleID)) is already in “\(conflict.owner.name)”",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.warn)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add profile" : "Save") { save() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(Tokens.Space.x6)
        }
        .frame(width: 560, height: 660)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
    }

    // MARK: Fields

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Icon").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(AppProfile.iconChoices, id: \.self) { icon in
                    Button { draft.symbolName = icon } label: {
                        IconTile(icon, tint: draft.symbolName == icon ? Tokens.Color.accent : Tokens.Color.textTert, size: 30)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(draft.symbolName == icon ? Tokens.Color.accent.opacity(0.6) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                Menu {
                    Section("Running now") {
                        ForEach(AppCatalog.runningApps(), id: \.bundleID) { app in
                            Button(app.name) { addApp(app.bundleID) }
                                .disabled(draft.bundleIDs.contains(app.bundleID))
                        }
                    }
                    Divider()
                    Button("Choose an app…") { chooseApp() }
                } label: {
                    Label("Add app", systemImage: "plus")
                        .font(Tokens.TypeScale.micro)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }

            if draft.bundleIDs.isEmpty {
                Text("Add at least one app. This profile only applies while one of them is in front.")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
                    .padding(.vertical, Tokens.Space.x2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(draft.bundleIDs.enumerated()), id: \.element) { index, bundleID in
                        HStack(spacing: Tokens.Space.x2) {
                            if let icon = AppCatalog.icon(for: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "questionmark.app.dashed")
                                    .foregroundStyle(Tokens.Color.textTert)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(AppCatalog.name(for: bundleID))
                                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.text)
                                Text(bundleID)
                                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if !AppCatalog.isInstalled(bundleID) {
                                Chip(text: "Not installed", tint: Tokens.Color.textTert, filled: false)
                            }
                            Button {
                                draft.bundleIDs.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Tokens.Color.textTert)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Tokens.Space.x3)
                        .padding(.vertical, 7)
                        if index < draft.bundleIDs.count - 1 {
                            Rectangle().fill(Tokens.Color.hairline).frame(height: 1).padding(.leading, 30)
                        }
                    }
                }
                .card(radius: Tokens.Radius.sm, padding: 0, elevated: false)
            }
        }
    }

    /// True once the profile claims at least one terminal — CLI targeting only
    /// means anything there.
    private var claimsTerminal: Bool {
        draft.bundleIDs.contains { AppContext.terminalBundleIDs.contains($0) }
    }

    /// Tools people actually dictate into. Free text is allowed too — the list
    /// is a shortcut, not a whitelist.
    private static let commonTools = ["claude", "codex", "aider", "gemini",
                                      "vim", "nvim", "nano", "psql", "irb", "python3"]

    private var cliToolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Command-line tools").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                TextField("claude", text: $newTool)
                    .textFieldStyle(.plain)
                    .font(Tokens.TypeScale.bodyMono)
                    .frame(width: 130)
                    .padding(.horizontal, Tokens.Space.x2).padding(.vertical, 5)
                    .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                    .onSubmit { addTool(newTool) }
                Button("Add") { addTool(newTool) }
                    .secondaryAction()
                    .disabled(newTool.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if draft.tools.isEmpty {
                Text("Leave empty to cover the whole terminal. Name a tool — claude, codex, vim — and this profile applies only while that program is in front, so a shell prompt and Claude Code can behave differently in the same window.")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Tokens.Space.x2) {
                    ForEach(draft.tools, id: \.self) { tool in
                        HStack(spacing: 5) {
                            Text(tool).font(Tokens.TypeScale.bodyMono)
                            Button { draft.tools.removeAll { $0 == tool } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Tokens.Color.accent)
                        .padding(.horizontal, Tokens.Space.x2).padding(.vertical, 4)
                        .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: Tokens.Space.x2) {
                ForEach(Self.commonTools.filter { !draft.tools.contains($0) }.prefix(6), id: \.self) { tool in
                    Button { addTool(tool) } label: {
                        Text(tool)
                            .font(Tokens.TypeScale.micro)
                            .foregroundStyle(Tokens.Color.textSec)
                            .padding(.horizontal, Tokens.Space.x2).padding(.vertical, 3)
                            .background(Capsule().fill(Tokens.Color.fillQuiet))
                            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            Text("NotchWhisper reads the foreground command of the focused tab — the same thing `ps` marks with a `+`. A tool launched through node or python is recognised by its script name, not the runtime.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addTool(_ raw: String) {
        let tool = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, !draft.tools.contains(tool) else { return }
        draft.tools.append(tool)
        newTool = ""
    }

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            Text("WHAT CHANGES IN THESE APPS")
                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                .foregroundStyle(Tokens.Color.textTert)

            OverridePicker(
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

            OverrideSwitch(title: "AI processing",
                           globalValue: settings.llmEnabled,
                           value: $draft.llmEnabled)

            OverridePicker(
                title: "AI connection",
                globalLabel: connections.active?.name ?? "None",
                selectionLabel: draft.connectionID.flatMap { connections.connection(id: $0)?.name ?? "Missing connection" },
                clear: { draft.connectionID = nil }
            ) {
                ForEach(connections.connections) { connection in
                    Button(connection.isLocal ? "\(connection.name) (on this Mac)" : connection.name) {
                        draft.connectionID = connection.id
                    }
                }
            }

            OverrideSwitch(title: "Type into the app",
                           globalValue: settings.autoTypeEnabled,
                           value: $draft.autoType)

            OverrideSwitch(title: "Newline after text",
                           globalValue: settings.insertNewline,
                           value: $draft.insertNewline)

            OverridePicker(
                title: "How the text is inserted",
                globalLabel: automaticInsertionLabel,
                selectionLabel: draft.insertionMode?.label,
                clear: { draft.insertionMode = nil }
            ) {
                ForEach(AutoTyper.InsertionMode.allCases) { mode in
                    Button(mode.label) { draft.insertionMode = mode }
                }
            }

            if claimsTerminal {
                Text("In a terminal, a typed newline presses Return and SUBMITS the line — a two-sentence dictation arrives as two half-messages. Pasting keeps it as one block; NotchWhisper puts the text on the clipboard, presses ⌘V and restores what was there.")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OverridePicker(
                title: "Model",
                globalLabel: ModelRegistry.shared.descriptor(for: settings.modelId).displayName,
                selectionLabel: draft.modelId.map { ModelRegistry.shared.descriptor(for: $0).displayName },
                clear: { draft.modelId = nil }
            ) {
                ForEach(ModelRegistry.shared.installedDescriptors, id: \.id) { model in
                    Button(model.displayName) { draft.modelId = model.id }
                }
            }

            Text("A model set here is applied before recording starts and takes priority over automatic model selection. It is never swapped during a recording.")
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    /// What "use global setting" resolves to for insertion — the automatic
    /// rule, not a fixed value, so the label must say which way it will go.
    private var automaticInsertionLabel: String {
        guard settings.pasteIntoTerminalTools, claimsTerminal else { return "Automatic (type it)" }
        return draft.targetsCLI ? "Automatic (paste it)" : "Automatic (type at a shell prompt)"
    }

    private func addApp(_ bundleID: String) {
        guard !draft.bundleIDs.contains(bundleID) else { return }
        draft.bundleIDs.append(bundleID)
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = store.uniqueName(basedOn: AppCatalog.name(for: bundleID))
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { addApp(bundleID) }
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew { store.add(draft) } else { store.update(draft) }
        dismiss()
    }
}

// MARK: - Override controls
//
// Every override has a visible "Use global setting" state. A nil that only
// shows as an unchecked box is indistinguishable from an explicit "off".

private struct OverrideSwitch: View {
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

private struct OverridePicker<Options: View>: View {
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

// MARK: - App catalog

/// Bundle-id → name/icon lookups, cached. `NSWorkspace` disk lookups are slow
/// enough to notice when a list redraws on every keystroke.
@MainActor
enum AppCatalog {
    private static var urlCache: [String: URL?] = [:]
    private static var iconCache: [String: NSImage] = [:]

    struct RunningApp: Hashable {
        var bundleID: String
        var name: String
    }

    static func url(for bundleID: String) -> URL? {
        if let cached = urlCache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urlCache[bundleID] = url
        return url
    }

    static func isInstalled(_ bundleID: String) -> Bool { url(for: bundleID) != nil }

    static func name(for bundleID: String) -> String {
        guard let url = url(for: bundleID) else { return bundleID }
        // Prefer the app's own display name; `FileManager.displayName` returns
        // "Terminal.app" when the user has file extensions shown.
        if let info = Bundle(url: url)?.infoDictionary,
           let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        iconCache[bundleID] = icon
        return icon
    }

    /// Regular (Dock-visible) apps running right now, minus ourselves.
    static func runningApps() -> [RunningApp] {
        let ours = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != ours else { return nil }
                return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .reduce(into: [RunningApp]()) { result, app in
                if !result.contains(where: { $0.bundleID == app.bundleID }) { result.append(app) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
