import Foundation
import SwiftUI

// MARK: - Providers
//
// A connection is "where the text is sent". Every backend the app talks to
// speaks the OpenAI chat-completions dialect, so a provider preset is nothing
// more than a sensible default address plus a hint about whether a key is
// needed — the wire protocol is identical for all of them.

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case lmStudio
    case llamaCpp
    case openAI
    case openRouter
    case groq
    case together
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama:     return "Ollama"
        case .lmStudio:   return "LM Studio"
        case .llamaCpp:   return "llama.cpp server"
        case .openAI:     return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .groq:       return "Groq"
        case .together:   return "Together AI"
        case .custom:     return "Custom (OpenAI-compatible)"
        }
    }

    /// Prefilled address when the preset is chosen.
    var defaultEndpoint: String {
        switch self {
        case .ollama:     return "http://localhost:11434/v1"
        case .lmStudio:   return "http://localhost:1234/v1"
        case .llamaCpp:   return "http://localhost:8080/v1"
        case .openAI:     return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq:       return "https://api.groq.com/openai/v1"
        case .together:   return "https://api.together.xyz/v1"
        case .custom:     return ""
        }
    }

    /// Example model name, shown as the field's placeholder.
    var modelPlaceholder: String {
        switch self {
        case .ollama:     return "llama3.2"
        case .lmStudio:   return "qwen2.5-7b-instruct"
        case .llamaCpp:   return "local-model"
        case .openAI:     return "gpt-4o-mini"
        case .openRouter: return "openai/gpt-4o-mini"
        case .groq:       return "llama-3.3-70b-versatile"
        case .together:   return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .custom:     return "model name"
        }
    }

    /// True when the service will reject a request without an API key. Only a
    /// hint for the UI — the key field is always available.
    var requiresKey: Bool {
        switch self {
        case .openAI, .openRouter, .groq, .together: return true
        case .ollama, .lmStudio, .llamaCpp, .custom: return false
        }
    }

    var symbolName: String {
        switch self {
        case .ollama, .lmStudio, .llamaCpp: return "desktopcomputer"
        case .openAI, .openRouter, .groq, .together: return "cloud"
        case .custom: return "link"
        }
    }

    /// Presets that run on the user's own machine, listed first in the picker.
    static let localPresets: [LLMProvider] = [.ollama, .lmStudio, .llamaCpp]
    static let cloudPresets: [LLMProvider] = [.openAI, .openRouter, .groq, .together]
}

// MARK: - Connection

/// One saved LLM endpoint. The API key is never part of this struct — it lives
/// in the Keychain under `keychainAccount` and is fetched on demand.
struct LLMConnection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var provider: LLMProvider
    var endpoint: String
    var model: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, provider: LLMProvider = .ollama,
         endpoint: String = "", model: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.createdAt = createdAt
    }

    /// Keychain account holding this connection's API key.
    var keychainAccount: String { "llm_connection_\(id.uuidString)" }

    var apiKey: String? { Keychain.get(account: keychainAccount) }
    var hasKey: Bool { !(apiKey ?? "").isEmpty }

    /// Whether the transcript stays on this Mac. Decided by the host, not by
    /// the preset — someone may point the "custom" preset at localhost, or run
    /// Ollama on a machine across the room.
    var isLocal: Bool {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host == "0.0.0.0" || host.hasSuffix(".local")
    }

    /// A connection can only be used once it has both an address and a model.
    var isUsable: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LLMServerClient.chatURL(from: endpoint) != nil
    }

    /// Short "host · model" line for list rows.
    var subtitle: String {
        let host = URL(string: endpoint)?.host ?? endpoint
        let m = model.isEmpty ? "no model set" : model
        return host.isEmpty ? m : "\(host) · \(m)"
    }
}

// MARK: - Store

/// Every configured LLM endpoint, plus which one is active. Persisted next to
/// the other app data in Application Support.
///
/// Exactly one connection is active at a time; processing modes run against it.
@MainActor final class LLMConnectionStore: ObservableObject {
    static let shared = LLMConnectionStore()

    @Published private(set) var connections: [LLMConnection] = []
    @Published private(set) var activeID: UUID?

    /// Live per-connection reachability, filled in by `test(_:)`.
    @Published var testResults: [UUID: TestResult] = [:]

    enum TestResult: Equatable {
        case testing
        case ok(String)
        case failed(String)
    }

    private let fileManager = FileManager.default
    private var url: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/llm-connections.json")
    }

    private struct Archive: Codable {
        var connections: [LLMConnection]
        var activeID: UUID?
    }

    private init() {
        load()
        migrateLegacySettingsIfNeeded()
        adoptLegacyAPIKeyIfNeeded()
    }

    // MARK: Access

    var active: LLMConnection? {
        guard let activeID else { return nil }
        return connections.first { $0.id == activeID }
    }

    /// True when there is an active connection that can actually be called.
    var hasUsableConnection: Bool { active?.isUsable == true }

    func connection(id: UUID) -> LLMConnection? { connections.first { $0.id == id } }

    // MARK: CRUD

    func add(_ connection: LLMConnection, apiKey: String?) {
        connections.append(connection)
        Keychain.set(apiKey, for: connection.keychainAccount)
        // The first connection someone creates is the one they meant to use.
        if activeID == nil { activeID = connection.id }
        persist()
    }

    func update(_ connection: LLMConnection, apiKey: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        // `nil` means "leave the stored key alone"; an empty string clears it.
        if let apiKey { Keychain.set(apiKey.isEmpty ? nil : apiKey, for: connection.keychainAccount) }
        persist()
    }

    func remove(_ connection: LLMConnection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.set(nil, for: connection.keychainAccount)
        testResults[connection.id] = nil
        if activeID == connection.id { activeID = connections.first?.id }
        persist()
    }

    func activate(_ connection: LLMConnection) {
        activeID = connection.id
        persist()
    }

    // MARK: Connectivity

    /// Tests a connection and records the outcome for the UI. Never throws.
    func test(_ connection: LLMConnection) async {
        testResults[connection.id] = .testing
        do {
            try await LLMServerClient.testConnection(
                endpoint: connection.endpoint, apiKey: connection.apiKey)
            testResults[connection.id] = .ok("Reachable")
        } catch {
            let reason = (error as? LLMServerError)?.errorDescription
                ?? "Couldn't reach the server."
            testResults[connection.id] = .failed(reason)
        }
    }

    // MARK: Persistence

    private func persist() {
        let archive = Archive(connections: connections, activeID: activeID)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else { return }
        connections = archive.connections
        activeID = archive.activeID.flatMap { id in
            archive.connections.contains { $0.id == id } ? id : nil
        } ?? archive.connections.first?.id
    }

    // MARK: Migration
    //
    // Before connections existed there was a single endpoint/model/key trio in
    // Settings. Lift it into a real connection once, so nobody has to retype
    // what they already configured.

    private enum LegacyKey {
        static let endpoint = "llmServerEndpoint"
        static let model    = "llmServerModel"
        static let migrated = "llmConnectionsMigrated"
        static let apiKeyAccount = "llm_server_api_key"
    }

    private func migrateLegacySettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: LegacyKey.migrated) else { return }
        defaults.set(true, forKey: LegacyKey.migrated)

        let endpoint = (defaults.string(forKey: LegacyKey.endpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, connections.isEmpty else { return }
        let model = defaults.string(forKey: LegacyKey.model) ?? ""
        let key = Keychain.get(account: LegacyKey.apiKeyAccount)

        let provider = LLMProvider.allCases.first { $0.defaultEndpoint == endpoint } ?? .custom
        let connection = LLMConnection(
            name: provider == .custom ? "My server" : provider.displayName,
            provider: provider, endpoint: endpoint, model: model
        )
        connections = [connection]
        activeID = connection.id
        Keychain.set(key, for: connection.keychainAccount)
        persist()
    }

    /// Moves the pre-connections API key onto the connection that inherited the
    /// old endpoint. Separate from the one-shot migration above and retried on
    /// every launch, because the key lives in the Keychain: a launch that can't
    /// read it (a differently-signed build, a denied prompt) must not lose it
    /// permanently by flipping the migration flag.
    private func adoptLegacyAPIKeyIfNeeded() {
        guard let legacy = Keychain.get(account: LegacyKey.apiKeyAccount), !legacy.isEmpty,
              let target = active ?? connections.first,
              !target.hasKey
        else { return }
        Keychain.set(legacy, for: target.keychainAccount)
        Keychain.set(nil, for: LegacyKey.apiKeyAccount)
    }
}
