import Foundation

// MARK: - Result

/// What happened to a transcript after the LLM pass.
enum LLMProcessResult: Equatable {
    /// The LLM produced polished text.
    case processed(String)
    /// Processing could not be used; the caller MUST keep the original text.
    case failed(String)
}

// MARK: - LLM Runner

/// Runs local-server LLM post-processing on a finished transcription.
///
/// The only backend is an OpenAI-compatible endpoint (Ollama, LM Studio,
/// Unsloth, or any local / remote server exposing /v1/chat/completions).
///
/// Guarantees:
///  · The original transcription is NEVER replaced by an empty/failed result.
///  · Long transcriptions are processed in paragraph chunks (never truncated).
@MainActor final class LLMRunner: ObservableObject {

    private let state: AppState
    private let settings: Settings

    init(_ state: AppState, _ settings: Settings) {
        self.state = state
        self.settings = settings
    }

    // MARK: - Public entry point

    /// Processes `transcript` with the configured mode/server, returning the
    /// polished text or `.failed`. `.failed` ALWAYS carries the reason the
    /// caller is expected to surface; the caller keeps the original.
    func process(_ transcript: String, mode: LLMMode) async -> LLMProcessResult {
        guard !transcript.isEmpty, mode != .original else {
            return .processed(transcript)
        }
        return await processServer(transcript, mode: mode)
    }

    // MARK: - Server path

    private func processServer(_ transcript: String, mode: LLMMode) async -> LLMProcessResult {
        let endpoint = settings.llmServerEndpoint
        let apiKey = Keychain.get(account: ServerKeychainAccount.llmAPIKey)
        guard LLMServerClient.chatURL(from: endpoint) != nil, !endpoint.isEmpty else {
            return .failed("The LLM server hasn't been configured. In Settings → Local LLM, enter the server address and model name.")
        }
        let model = settings.llmServerModel
        guard !model.isEmpty else {
            return .failed("No model name is set for the server. In Settings → Local LLM, set the model name served by \"\(endpoint)\".")
        }

        let system = LLMPrompts.systemPrompt(for: mode, custom: settings.customPrompt)
        // Conservative chunk size: Ollama defaults `num_ctx` to 4096 tokens, so
        // a chunk + system prompt + the model's own reply must fit well under
        // that. ~6000 chars ≈ 1800 tokens leaves room for the response.
        let chunks = TextChunker.chunks(of: transcript, budget: 6_000)
        var outputs: [String] = []
        let total = chunks.count
        for (index, chunk) in chunks.enumerated() {
            updateStatus("Improving…", part: index + 1, total: total)
            let messages = [
                LLMServerClient.ChatMessage(role: "system", content: system),
                LLMServerClient.ChatMessage(role: "user", content: LLMPrompts.userMessage(for: chunk)),
            ]
            do {
                let completion = try await LLMServerClient.chat(
                    endpoint: endpoint, model: model, messages: messages, apiKey: apiKey,
                    temperature: mode.temperature,
                    maxTokens: maxTokens(forInputChars: chunk.count)
                )
                let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    outputs.append(text)
                }
            } catch {
                state.statusMessage = ""
                if Task.isCancelled {
                    return .failed("Processing was cancelled.")
                }
                fputs("NotchWhisper: LLM server error: \(error)\n", stderr)
                return .failed(friendlyMessage(from: error, endpoint: endpoint))
            }
        }
        state.statusMessage = ""
        // Never replace dictated text with an empty result.
        if outputs.isEmpty {
            return .failed("The server returned an empty response. The original transcription was kept.")
        }
        if outputs.count == 1 {
            return .processed(outputs[0])
        }
        // Multi-chunk: summarize / actions / structured must be RE-REDUCED into
        // one document, not concatenated (otherwise a long memo yields N
        // disjoint summaries). Prose modes concatenate in order.
        if mode.reducesAcrossChunks {
            state.statusMessage = "Combining \(total) parts…"
            let messages = [
                LLMServerClient.ChatMessage(
                    role: "system",
                    content: LLMPrompts.reduceSystemPrompt(for: mode, custom: settings.customPrompt)),
                LLMServerClient.ChatMessage(
                    role: "user", content: LLMPrompts.reduceUserMessage(for: outputs)),
            ]
            if let completion = try? await LLMServerClient.chat(
                endpoint: endpoint, model: model, messages: messages, apiKey: apiKey,
                temperature: mode.temperature,
                maxTokens: maxTokens(forInputChars: outputs.joined().count)
            ), !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.statusMessage = ""
                return .processed(completion.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Reduce pass failed — fall back to the ordered join rather than
            // losing everything.
        }
        state.statusMessage = ""
        return .processed(stitchedOutput(outputs, mode: mode))
    }

    /// Output token budget: roughly the input size (these tasks never need to
    /// produce much more than they consume) plus headroom, clamped so a stray
    /// runaway generation can't hang for minutes.
    private func maxTokens(forInputChars chars: Int) -> Int {
        let approxInputTokens = chars / 4
        return min(8192, max(1024, approxInputTokens + 512))
    }

    // MARK: - Helpers

    private func updateStatus(_ message: String, part: Int, total: Int) {
        if total > 1 {
            state.statusMessage = "\(message) — processing part \(part) of \(total)"
        } else {
            state.statusMessage = message
        }
    }

    /// Joins per-chunk outputs into the final result.
    private func stitchedOutput(_ outputs: [String], mode: LLMMode) -> String {
        _ = mode
        return outputs.joined(separator: "\n\n")
    }

    private func friendlyMessage(from error: Error, endpoint: String) -> String {
        if let llmErr = error as? LLMServerError, let desc = llmErr.errorDescription {
            return desc
        }
        return "Processing failed — check that your server at \"\(endpoint)\" is running and supports OpenAI-compatible chat completions."
    }
}

// MARK: - Server keychain constant

enum ServerKeychainAccount {
    static let llmAPIKey = "llm_server_api_key"
}


// MARK: - Chunking

/// Paragraph-aware text splitting so long dictations are processed in
/// predictable pieces (never truncated, never silently dropped).
enum TextChunker {

    /// Splits `text` into ≤ `budget`-char pieces on paragraph boundaries,
    /// falling back to sentence and then hard cuts.
    static func chunks(of text: String, budget: Int) -> [String] {
        guard text.count > budget else { return [text] }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.count <= 1 {
            return sentenceChunks(text, budget: budget)
        }
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= budget {
                current += "\n\n" + paragraph
            } else {
                result.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }

    private static func sentenceChunks(_ text: String, budget: Int) -> [String] {
        let sentences = text.components(separatedBy: ". ")
        var result: [String] = []
        var current = ""
        for sentence in sentences {
            let piece = sentence.hasSuffix(".") ? sentence : sentence + "."
            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 1 <= budget {
                current += " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        // Hard fallback for a single sentence longer than the budget.
        if result.isEmpty {
            var start = text.startIndex
            var cuts: [String] = []
            while start < text.endIndex {
                let end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
                cuts.append(String(text[start..<end]))
                start = end
            }
            return cuts.isEmpty ? [text] : cuts
        }
        return result
    }
}