import Foundation

// MARK: - Server error mapping

/// What went wrong with a server request, in user-friendly terms.
enum LLMServerError: LocalizedError {
    case badEndpoint(String)
    case unreachable
    case authFailed
    case modelNotFound(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .badEndpoint(let detail):
            return "The server address couldn't be read: \(detail)"
        case .unreachable:
            return "Can't connect to the server. Check that your local LLM application is running and that the address is correct."
        case .authFailed:
            return "The server rejected the API key. Check the key and try again."
        case .modelNotFound(let name):
            return "The server doesn't have a model named \"\(name)\". Check the model name in your LLM application."
        case .serverError(let detail):
            return "The server returned an error: \(detail)"
        }
    }
}

// MARK: - OpenAI-compatible chat client

/// Minimal chat-completions client for local LLM servers (Ollama, LM Studio,
/// Unsloth, or anything exposing /v1/chat/completions). Foundation only — no
/// third-party networking lib.
enum LLMServerClient {

    static let defaultEndpoint = "http://localhost:11434/v1"

    // MARK: Normalization

    /// Turns the raw endpoint into a chat-completions URL:
    ///   http://localhost:11434            → http://localhost:11434/v1/chat/completions
    ///   http://localhost:11434/v1         → http://localhost:11434/v1/chat/completions
    ///   http://localhost:11434/chat/completions → itself
    static func chatURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if !lower.hasSuffix("/chat/completions") {
            if !lower.hasSuffix("/v1") {
                s += "/v1"
            }
            s += "/chat/completions"
        }
        return URL(string: s)
    }

    // MARK: Request

    struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
    }

    struct Completion {
        let text: String
        let model: String?
        let promptTokens: Int?
        let completionTokens: Int?
    }

    /// Sends a chat completion request and returns the reply.
    static func chat(
        endpoint: String,
        model: String,
        messages: [ChatMessage],
        apiKey: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 180
    ) async throws -> Completion {
        guard let url = chatURL(from: endpoint) else {
            throw LLMServerError.badEndpoint("the URL didn't parse: \"\(endpoint)\"")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = RequestBody(
            model: model,
            messages: messages,
            temperature: temperature,
            max_tokens: maxTokens,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMServerError.unreachable
        }
        guard let http = resp as? HTTPURLResponse else {
            throw LLMServerError.unreachable
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw LLMServerError.authFailed
        case 404:
            throw LLMServerError.modelNotFound(model)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = firstJSONStringField(body, keys: ["message", "error"])
                ?? "HTTP \(http.statusCode)"
            throw LLMServerError.serverError(detail)
        }

        // Parse the JSON response (variadic shape across servers).
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServerError.serverError("the response wasn't valid JSON")
        }
        if let errorObj = obj["error"] as? [String: Any],
           let msg = errorObj["message"] as? String {
            throw LLMServerError.serverError(msg)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let text = (first["message"] as? [String: Any])?["content"] as? String
        else {
            throw LLMServerError.serverError("the response had no message content")
        }
        var promptTokens: Int?
        var completionTokens: Int?
        if let usage = obj["usage"] as? [String: Any] {
            promptTokens = usage["prompt_tokens"] as? Int
            completionTokens = usage["completion_tokens"] as? Int
        }
        return Completion(
            text: text, model: obj["model"] as? String,
            promptTokens: promptTokens, completionTokens: completionTokens
        )
    }

    // MARK: Connection test

    /// Ultra-light connectivity check: GET on the server base. Some servers
    /// only answer POST, so we treat any HTTP response (even 4xx/5xx) as
    /// "reachable"; transport errors fail the test.
    static func testConnection(endpoint: String, apiKey: String?) async throws {
        var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let targets: [URL]
        if let chat = chatURL(from: s) {
            let base = chat
                .deletingLastPathComponent()   // /v1
                .deletingLastPathComponent()   // host root
            targets = [base, chat]
        } else {
            targets = [URL(string: s)].compactMap { $0 }
        }
        for url in targets {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, 200..<500 ~= http.statusCode {
                    return   // reachable and answering
                }
            } catch {
                continue
            }
        }
        throw LLMServerError.unreachable
    }

    /// Extracts the first string value for any of `keys` from a JSON blob
    /// (server error-body parsing for friendly messages).
    private static func firstJSONStringField(_ json: String, keys: [String]) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        if let err = obj["error"] as? [String: Any] {
            for key in keys {
                if let v = err[key] as? String, !v.isEmpty { return v }
            }
        }
        return nil
    }
}