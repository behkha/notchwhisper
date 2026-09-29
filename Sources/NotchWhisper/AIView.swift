import SwiftUI

// MARK: - AI page
//
// Two things live here, in the order you need them:
//   1. Connections — WHERE text is sent (an OpenAI-compatible endpoint).
//   2. Modes       — WHAT is done to it, including modes the user writes.
// A mode can't run without a connection, so the page says so plainly rather
// than letting someone build a mode that silently never fires.

enum AITab: String, CaseIterable, Identifiable {
    case connections, modes
    var id: String { rawValue }
    var label: String { self == .connections ? "Connections" : "Modes" }
}

struct AIView: View {
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var connections = LLMConnectionStore.shared
    @ObservedObject private var modes = CustomModeStore.shared
    @ObservedObject private var theme = Tokens.ThemeManager.shared

    @Binding var tab: AITab
    @ViewState private var editingConnection: LLMConnection?
    @ViewState private var editingMode: CustomMode?
    @ViewState private var connectionToDelete: LLMConnection?
    @ViewState private var modeToDelete: CustomMode?

    var body: some View {
        let _ = theme.theme
        PageScroll(spacing: Tokens.Space.x6) {
            SectionHeader("AI", eyebrow: subtitleEyebrow,
                          subtitle: "Connect a model, then teach it the ways you want your dictation written.") {
                Button {
                    if tab == .connections { newConnection() } else { newMode() }
                } label: {
                    Label(tab == .connections ? "New Connection" : "New Mode", systemImage: "plus")
                }
                .primaryAction()
                .disabled(tab == .modes && !connections.hasUsableConnection)
            }

            SegmentedTabs(options: AITab.allCases.map { ($0, $0.label) }, selection: $tab)

            switch tab {
            case .connections: connectionsSection
            case .modes:       modesSection
            }
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionEditor(connection: connection)
        }
        .sheet(item: $editingMode) { mode in
            ModeEditor(mode: mode)
        }
        .confirmationDialog("Delete this connection?",
                            isPresented: Binding(get: { connectionToDelete != nil },
                                                 set: { if !$0 { connectionToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(connectionToDelete?.name ?? "")", role: .destructive) {
                if let c = connectionToDelete { connections.remove(c) }
                connectionToDelete = nil
            }
            Button("Cancel", role: .cancel) { connectionToDelete = nil }
        } message: {
            Text("Its API key is removed from the Keychain too. Modes stay, but they need an active connection to run.")
        }
        .confirmationDialog("Delete this mode?",
                            isPresented: Binding(get: { modeToDelete != nil },
                                                 set: { if !$0 { modeToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(modeToDelete?.name ?? "")", role: .destructive) {
                if let m = modeToDelete { deleteMode(m) }
                modeToDelete = nil
            }
            Button("Cancel", role: .cancel) { modeToDelete = nil }
        }
    }

    private var subtitleEyebrow: String {
        let c = connections.connections.count
        let m = modes.modes.count
        return "\(c) connection\(c == 1 ? "" : "s") · \(m) mode\(m == 1 ? "" : "s")"
    }

    // MARK: Connections

    @ViewBuilder
    private var connectionsSection: some View {
        if connections.connections.isEmpty {
            EmptyStateView(
                icon: "link",
                title: "No connections yet",
                message: "Point NotchWhisper at a model — Ollama or LM Studio on this Mac, or a hosted service. One connection is enough to unlock every processing mode.",
                actionTitle: "Add your first connection",
                action: { newConnection() }
            )
            .frame(height: 300)
            .card(padding: nil, elevated: false)
        } else {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                GroupedList(connections.connections, onSelect: { editingConnection = $0 }) { connection in
                    ConnectionCard(
                        connection: connection,
                        isActive: connections.activeID == connection.id,
                        result: connections.testResults[connection.id],
                        activate: { connections.activate(connection) },
                        edit: { editingConnection = connection },
                        test: { Task { await connections.test(connection) } },
                        remove: { connectionToDelete = connection }
                    )
                }

                Text("Transcripts are sent to the active connection each time a processing mode runs. A connection on localhost keeps everything on this Mac; a hosted one sends your text to that provider.")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Space.x1)
            }
        }
    }

    // MARK: Modes

    @ViewBuilder
    private var modesSection: some View {
        if !connections.hasUsableConnection {
            lockedBanner
        }

        if modes.modes.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Write your own mode",
                    message: "A mode is a name plus instructions — “Technical Writing: use precise technical language, never simplify product names.” Pick it before you dictate and every transcript comes out that way.",
                    actionTitle: connections.hasUsableConnection ? "New mode" : nil,
                    action: connections.hasUsableConnection ? { newMode() } : nil
                )
                .frame(height: 310)
                .card(padding: nil, elevated: false)

                templatesRow
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                GroupLabel("Your modes") {
                    Text("\(modes.modes.count)")
                        .font(Tokens.TypeScale.caption).monospacedDigit()
                        .foregroundStyle(Tokens.Color.textTert)
                }
                GroupedList(modes.modes, onSelect: { editingMode = $0 }) { mode in
                    ModeCard(
                        mode: mode,
                        isActive: settings.processingMode == .custom(mode.id),
                        canRun: connections.hasUsableConnection,
                        use: { settings.processingMode = .custom(mode.id) },
                        edit: { editingMode = mode },
                        duplicate: { duplicate(mode) },
                        remove: { modeToDelete = mode }
                    )
                }
            }
            templatesRow
        }
    }

    private var lockedBanner: some View {
        NoticeBanner(icon: "lock.fill", title: "Modes need an AI connection",
                     message: "Add a connection with an address and a model name, then come back here to write modes.") {
            Button("Add Connection") { tab = .connections; newConnection() }
                .secondaryAction()
        }
    }

    private var templatesRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            GroupLabel("Start from a template")
            FlowLayout {
                ForEach(CustomMode.templates) { template in
                    Button {
                        var copy = template
                        copy.id = UUID()
                        copy.name = modes.uniqueName(basedOn: template.name)
                        editingMode = copy
                    } label: {
                        Label(template.name, systemImage: template.symbolName)
                            .font(Tokens.TypeScale.callout)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .secondaryAction()
                    .disabled(!connections.hasUsableConnection)
                }
            }
        }
    }

    // MARK: Actions

    private func newConnection() {
        let preset = LLMProvider.ollama
        editingConnection = LLMConnection(
            name: preset.displayName, provider: preset,
            endpoint: preset.defaultEndpoint, model: ""
        )
    }

    private func newMode() {
        editingMode = CustomMode(name: "", instructions: "")
    }

    private func duplicate(_ mode: CustomMode) {
        var copy = mode
        copy.id = UUID()
        copy.name = modes.uniqueName(basedOn: mode.name)
        copy.createdAt = Date()
        copy.updatedAt = Date()
        modes.add(copy)
    }

    /// Deleting the selected mode must not leave the pipeline pointing at
    /// something that no longer exists.
    private func deleteMode(_ mode: CustomMode) {
        if settings.processingMode == .custom(mode.id) {
            settings.processingMode = .off
        }
        modes.remove(mode)
    }
}

// MARK: - Connection card

private struct ConnectionCard: View {
    let connection: LLMConnection
    let isActive: Bool
    let result: LLMConnectionStore.TestResult?
    let activate: () -> Void
    let edit: () -> Void
    let test: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x3) {
            IconTile(connection.provider.symbolName,
                     tint: isActive ? Tokens.Color.accent : Tokens.Color.textSec, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(connection.name)
                        .font(Tokens.TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Color.text)
                    if isActive { Chip(text: "Active", tint: Tokens.Color.accent) }
                    Chip(text: connection.isLocal ? "On this Mac" : "Cloud",
                         systemImage: connection.isLocal ? "desktopcomputer" : "cloud",
                         tint: connection.isLocal ? Tokens.Color.success : Tokens.Color.warn)
                    if !connection.isUsable {
                        Chip(text: "Incomplete", tint: Tokens.Color.danger)
                    }
                }
                Text(connection.subtitle)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textTert)
                    .lineLimit(1).truncationMode(.middle)
                if let result { testLine(result) }
            }

            Spacer(minLength: Tokens.Space.x3)

            HStack(spacing: Tokens.Space.x1) {
                if !isActive {
                    Button("Use") { activate() }
                        .secondaryAction()
                        .disabled(!connection.isUsable)
                }
                MoreMenu {
                    Button("Edit…") { edit() }
                    Button("Test connection") { test() }
                    if !isActive { Button("Make active") { activate() }.disabled(!connection.isUsable) }
                    Divider()
                    Button("Delete", role: .destructive) { remove() }
                }
            }
        }
    }

    @ViewBuilder
    private func testLine(_ result: LLMConnectionStore.TestResult) -> some View {
        switch result {
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Mode card

private struct ModeCard: View {
    let mode: CustomMode
    let isActive: Bool
    let canRun: Bool
    let use: () -> Void
    let edit: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.x3) {
            IconTile(mode.symbolName, tint: isActive ? Tokens.Color.accent : Tokens.Color.textSec, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Tokens.Space.x2) {
                    Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                        .font(Tokens.TypeScale.body.weight(.semibold))
                        .foregroundStyle(Tokens.Color.text)
                    if isActive { Chip(text: "Selected", tint: Tokens.Color.accent) }
                }
                Text(mode.instructions)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textSec)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Chip(text: mode.creativity.label, tint: Tokens.Color.textSec, filled: false)
                    if mode.singleDocument {
                        Chip(text: "One document", systemImage: "doc.text",
                             tint: Tokens.Color.textSec, filled: false)
                    }
                }
                .padding(.top, 1)
            }

            Spacer(minLength: Tokens.Space.x3)

            HStack(spacing: Tokens.Space.x1) {
                if !isActive {
                    Button("Use") { use() }
                        .secondaryAction()
                        .disabled(!canRun)
                }
                MoreMenu {
                    Button("Edit…") { edit() }
                    Button("Duplicate") { duplicate() }
                    if !isActive { Button("Use for dictation") { use() }.disabled(!canRun) }
                    Divider()
                    Button("Delete", role: .destructive) { remove() }
                }
            }
        }
    }
}
