import SwiftUI

// MARK: - Connection editor

/// Add or edit one LLM connection. The API key is read from (and written to)
/// the Keychain — it is never held in the archive on disk.
struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LLMConnectionStore.shared

    let connection: LLMConnection

    @State private var name: String
    @State private var provider: LLMProvider
    @State private var endpoint: String
    @State private var model: String
    @State private var apiKey: String = ""
    @State private var keyLoaded = false

    @State private var isTesting = false
    @State private var testMessage: (text: String, ok: Bool)?
    @State private var isFetchingModels = false
    @State private var availableModels: [String] = []
    @State private var modelsMessage: String?

    init(connection: LLMConnection) {
        self.connection = connection
        _name = State(initialValue: connection.name)
        _provider = State(initialValue: connection.provider)
        _endpoint = State(initialValue: connection.endpoint)
        _model = State(initialValue: connection.model)
    }

    private var isNew: Bool { store.connection(id: connection.id) == nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LLMServerClient.chatURL(from: endpoint) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New connection" : "Edit connection")
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.top, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                    providerField
                    LabeledField("Name", text: $name, placeholder: "My Ollama")
                    LabeledField("Address", text: $endpoint, placeholder: provider.defaultEndpoint.isEmpty
                          ? "http://localhost:11434/v1" : provider.defaultEndpoint,
                          mono: true,
                          help: "The OpenAI-compatible base URL. NotchWhisper appends /chat/completions itself.")
                    modelField
                    apiKeyField
                    testRow
                    privacyNote
                }
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)
            }
            .scrollIndicators(.never)

            Divider().overlay(Tokens.Color.hairline)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add connection" : "Save") { save() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(Tokens.Space.x6)
        }
        .frame(width: 540, height: 620)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
        .onAppear {
            if !keyLoaded {
                apiKey = connection.apiKey ?? ""
                keyLoaded = true
            }
        }
    }

    // MARK: Fields

    private var providerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            Picker("", selection: $provider) {
                Section("On this Mac") {
                    ForEach(LLMProvider.localPresets) { Text($0.displayName).tag($0) }
                }
                Section("Hosted") {
                    ForEach(LLMProvider.cloudPresets) { Text($0.displayName).tag($0) }
                }
                Text(LLMProvider.custom.displayName).tag(LLMProvider.custom)
            }
            .labelsHidden().pickerStyle(.menu)
            .onChange(of: provider) { old, new in
                // Only overwrite fields the user hasn't personalized.
                if endpoint.isEmpty || endpoint == old.defaultEndpoint { endpoint = new.defaultEndpoint }
                if name.isEmpty || name == old.displayName { name = new.displayName }
                availableModels = []
                modelsMessage = nil
                testMessage = nil
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                if availableModels.isEmpty {
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack(spacing: 5) {
                            if isFetchingModels { ProgressView().controlSize(.small) }
                            Text(isFetchingModels ? "Loading…" : "List models")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                    .disabled(isFetchingModels || LLMServerClient.chatURL(from: endpoint) == nil)
                } else {
                    Menu("Choose (\(availableModels.count))") {
                        ForEach(availableModels, id: \.self) { candidate in
                            Button(candidate) { model = candidate }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                    .frame(width: 130)
                }
            }
            TextField(provider.modelPlaceholder, text: $model)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.bodyMono)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 9)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            if let modelsMessage {
                Text(modelsMessage)
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The exact model name this server serves. Processing can't run without it.")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("API key").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                Text(provider.requiresKey ? "Required" : "Optional")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
            SecureField(provider.requiresKey ? "sk-…" : "Leave empty if not required", text: $apiKey)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 9)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            Text("Stored in your macOS Keychain, never in the app's files.")
                .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
        }
    }

    private var testRow: some View {
        HStack(spacing: Tokens.Space.x3) {
            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 6) {
                    if isTesting { ProgressView().controlSize(.small) }
                    Text(isTesting ? "Testing…" : "Test connection")
                }
            }
            .secondaryAction()
            .disabled(isTesting || LLMServerClient.chatURL(from: endpoint) == nil)

            if let testMessage {
                Label(testMessage.text,
                      systemImage: testMessage.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(testMessage.ok ? Tokens.Color.success : Tokens.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var privacyNote: some View {
        let local = LLMConnection(name: name, provider: provider, endpoint: endpoint, model: model).isLocal
        return HStack(alignment: .top, spacing: Tokens.Space.x2) {
            Image(systemName: local ? "lock.fill" : "cloud")
                .font(.system(size: 11)).foregroundStyle(local ? Tokens.Color.success : Tokens.Color.warn)
                .padding(.top, 1)
            Text(local
                 ? "This address is on your Mac — transcripts never leave the machine."
                 : "This is a remote service. Transcripts you process are sent to it.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.x3)
        .background(Tokens.Color.fillQuieter, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
    }

    // MARK: Actions

    private func fetchModels() async {
        isFetchingModels = true
        modelsMessage = nil
        do {
            let names = try await LLMServerClient.listModels(endpoint: endpoint, apiKey: currentKey)
            availableModels = names
            if names.isEmpty {
                modelsMessage = "The server didn't list any models."
            } else if model.isEmpty {
                model = names[0]
            }
        } catch {
            modelsMessage = (error as? LLMServerError)?.errorDescription
                ?? "Couldn't list the server's models — type the name instead."
        }
        isFetchingModels = false
    }

    private func test() async {
        isTesting = true
        testMessage = nil
        do {
            try await LLMServerClient.testConnection(endpoint: endpoint, apiKey: currentKey)
            testMessage = ("Reachable", true)
        } catch {
            testMessage = ((error as? LLMServerError)?.errorDescription
                           ?? "Couldn't reach the server.", false)
        }
        isTesting = false
    }

    private var currentKey: String? { apiKey.isEmpty ? nil : apiKey }

    private func save() {
        var updated = connection
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.provider = provider
        updated.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            store.add(updated, apiKey: currentKey)
        } else {
            store.update(updated, apiKey: apiKey)
        }
        dismiss()
    }
}

// MARK: - Mode editor

/// Write a mode: a name and the instructions that go to the model. The preview
/// runs the real pipeline against sample text so the instructions can be tuned
/// here rather than by dictating over and over.
struct ModeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CustomModeStore.shared
    @ObservedObject private var connections = LLMConnectionStore.shared

    let mode: CustomMode

    @State private var name: String
    @State private var instructions: String
    @State private var symbolName: String
    @State private var creativity: ModeCreativity
    @State private var singleDocument: Bool

    @State private var sampleText: String
    @State private var previewResult: String?
    @State private var previewError: String?
    @State private var isPreviewing = false
    @State private var showAdvanced = false

    private static let defaultSample =
        "so um i think we should ship the new parser on friday, it fixes the token cache bug that keeps hitting the ingest service, and uh we still need to update the docs"

    init(mode: CustomMode) {
        self.mode = mode
        _name = State(initialValue: mode.name)
        _instructions = State(initialValue: mode.instructions)
        _symbolName = State(initialValue: mode.symbolName)
        _creativity = State(initialValue: mode.creativity)
        _singleDocument = State(initialValue: mode.singleDocument)
        _sampleText = State(initialValue: Self.defaultSample)
    }

    private var isNew: Bool { store.mode(id: mode.id) == nil }

    private var nameConflict: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return store.modes.contains { $0.id != mode.id && $0.name.lowercased() == trimmed }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !nameConflict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.x3) {
                IconTile(symbolName, size: 32)
                Text(isNew ? "New mode" : "Edit mode")
                    .font(Tokens.TypeScale.title2)
                    .foregroundStyle(Tokens.Color.text)
                Spacer()
            }
            .padding(.horizontal, Tokens.Space.x6)
            .padding(.top, Tokens.Space.x6)
            .padding(.bottom, Tokens.Space.x4)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x4) {
                    nameField
                    instructionsField
                    iconPicker
                    creativityPicker
                    advancedSection
                    previewSection
                }
                .padding(.horizontal, Tokens.Space.x6)
                .padding(.bottom, Tokens.Space.x4)
            }
            .scrollIndicators(.never)

            Divider().overlay(Tokens.Color.hairline)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create mode" : "Save") { save() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(Tokens.Space.x6)
        }
        .frame(width: 560, height: 680)
        .background(AuroraBackground())
        .environment(\.colorScheme, .dark)
        .tint(Tokens.Color.accent)
        .focusEffectDisabled()
    }

    // MARK: Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            TextField("Technical Writing", text: $name)
                .textFieldStyle(.plain)
                .font(Tokens.TypeScale.body)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 9)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(nameConflict ? Tokens.Color.danger.opacity(0.6) : Tokens.Color.hairline, lineWidth: 1))
            if nameConflict {
                Label("Another mode already uses that name.", systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.warn)
            } else {
                Text("Shown in the mode picker and the menu bar.")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
        }
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Instructions").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            TextEditor(text: $instructions)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 132)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Space.x2)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            Text("Write what you'd tell an editor. One instruction per line works well — “Use precise technical language.” “Preserve code identifiers exactly.”")
                .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
                ForEach(CustomMode.iconChoices, id: \.self) { icon in
                    Button { symbolName = icon } label: {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(symbolName == icon ? Tokens.Color.accent : Tokens.Color.textSec)
                            .frame(width: 34, height: 30)
                            .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .fill(symbolName == icon ? Tokens.Color.accent.opacity(0.16) : Tokens.Color.fillQuiet))
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .strokeBorder(symbolName == icon ? Tokens.Color.accent.opacity(0.4) : Tokens.Color.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var creativityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latitude").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            Picker("", selection: $creativity) {
                ForEach(ModeCreativity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(creativity.blurb)
                .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Button(showAdvanced ? "Hide long-dictation option" : "Long dictations") {
                withAnimation(Tokens.Motion.ease) { showAdvanced.toggle() }
            }
            .buttonStyle(.plain)
            .font(Tokens.TypeScale.caption)
            .foregroundStyle(Tokens.Color.accent)

            if showAdvanced {
                HStack(alignment: .top, spacing: Tokens.Space.x3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Produce one combined result")
                            .font(Tokens.TypeScale.captionSB).foregroundStyle(Tokens.Color.text)
                        Text("Long transcripts are processed in parts. Turn this on for modes that should end up as a single document — a summary, minutes, one list. Leave it off for styles that transform text as it goes.")
                            .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Tokens.Space.x2)
                    Toggle("", isOn: $singleDocument).labelsHidden().toggleStyle(.switch)
                }
                .padding(Tokens.Space.x3)
                .background(Tokens.Color.fillQuieter, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack {
                Text("Try it").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                Spacer()
                Button {
                    Task { await runPreview() }
                } label: {
                    HStack(spacing: 5) {
                        if isPreviewing { ProgressView().controlSize(.small) }
                        Text(isPreviewing ? "Running…" : "Run on sample")
                    }
                }
                .buttonStyle(.plain)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.accent)
                .disabled(isPreviewing || connections.active == nil
                          || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $sampleText)
                .font(.system(size: 12))
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Space.x2)
                .background(Tokens.Color.fillQuieter, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1))

            if connections.active == nil {
                Text("Add an AI connection to try a mode here.")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let previewResult {
                Text(previewResult)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Tokens.Space.x3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Color.accent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            }
        }
    }

    private func runPreview() async {
        guard let connection = connections.active, let runner = AppDelegate.shared?.llmRunnerRef else { return }
        isPreviewing = true
        previewError = nil
        previewResult = nil
        var draft = mode
        draft.name = name.isEmpty ? "Untitled mode" : name
        draft.instructions = instructions
        draft.creativity = creativity
        draft.singleDocument = singleDocument
        switch await runner.preview(sampleText, mode: draft, connection: connection) {
        case .processed(let text): previewResult = text
        case .failed(let reason):  previewError = reason
        }
        isPreviewing = false
    }

    private func save() {
        var updated = mode
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.symbolName = symbolName
        updated.creativity = creativity
        updated.singleDocument = singleDocument
        if isNew {
            updated.createdAt = Date()
            updated.updatedAt = Date()
            store.add(updated)
        } else {
            store.update(updated)
        }
        dismiss()
    }
}

// MARK: - Shared field

/// A labeled plain text field matching the app's sheets.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var mono = false
    var help: String? = nil

    init(_ label: String, text: Binding<String>, placeholder: String = "",
         mono: Bool = false, help: String? = nil) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.mono = mono
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Tokens.TypeScale.bodyMono : Tokens.TypeScale.body)
                .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 9)
                .background(Tokens.Color.fillQuiet, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            if let help {
                Text(help).font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
