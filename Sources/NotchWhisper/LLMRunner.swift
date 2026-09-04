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

/// Runs LLM post-processing on a finished transcription.
///
/// Where the text goes is decided by the ACTIVE connection in
/// `LLMConnectionStore` — any OpenAI-compatible endpoint (Ollama, LM Studio,
/// llama.cpp, OpenAI, OpenRouter…). What happens to it is decided by the
/// selected `ProcessingMode`: one of the modes the user owns, or none at all.
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

    /// Processes `transcript` with the selected mode, using the active LLM
    /// connection. Returns the polished text or `.failed`; `.failed` ALWAYS
    /// carries the reason the caller is expected to surface, and the caller
    /// keeps the original text.
    /// `connectionID` pins a specific connection — an app profile can send
    /// work apps to the local endpoint while the global default is hosted.
    /// A pinned connection that no longer exists FAILS rather than falling back
    /// to the active one, which could be a different provider entirely.
    func process(_ transcript: String, mode: ProcessingMode,
                 connectionID: UUID? = nil) async -> LLMProcessResult {
        guard !transcript.isEmpty, !mode.isPassthrough else {
            return .processed(transcript)
        }
        guard let resolved = CustomModeStore.shared.resolve(mode) else {
            return .failed("The selected mode no longer exists. Pick a mode on the AI page.")
        }
        if let connectionID, LLMConnectionStore.shared.connection(id: connectionID) == nil {
            return .failed("The AI connection this app profile uses was deleted. Pick another one on the Apps page.")
        }
        let pinned = connectionID.flatMap { LLMConnectionStore.shared.connection(id: $0) }
        guard let connection = pinned ?? LLMConnectionStore.shared.active else {
            return .failed("No AI connection is active. Add one on the AI page to use processing modes.")
        }
        guard connection.isUsable else {
            return .failed("The \"\(connection.name)\" connection is incomplete — set its address and model name on the AI page.")
        }
        return await run(transcript, resolved: resolved, connection: connection, reportStatus: true)
    }

    /// One-shot run used by the mode editor's preview. Same pipeline, but it
    /// never touches the app's status line.
    func preview(_ transcript: String, mode: CustomMode, connection: LLMConnection) async -> LLMProcessResult {
        let resolved = ResolvedMode(
            displayName: mode.name,
            symbolName: mode.symbolName,
            temperature: mode.creativity.temperature,
            reducesAcrossChunks: mode.singleDocument,
            systemPrompt: LLMPrompts.systemPrompt(forCustom: mode),
            reduceSystemPrompt: LLMPrompts.reduceSystemPrompt(forCustom: mode)
        )
        return await run(transcript, resolved: resolved, connection: connection, reportStatus: false)
    }

    // MARK: - Server path

    private func run(_ transcript: String, resolved: ResolvedMode,
                     connection: LLMConnection, reportStatus: Bool) async -> LLMProcessResult {
        let endpoint = connection.endpoint
        let model = connection.model
        let apiKey = connection.apiKey

        // Conservative chunk size: Ollama defaults `num_ctx` to 4096 tokens, so
        // a chunk + system prompt + the model's own reply must fit well under
        // that. ~6000 chars ≈ 1800 tokens leaves room for the response.
        let chunks = TextChunker.chunks(of: transcript, budget: 6_000)
        var outputs: [String] = []
        let total = chunks.count
        for (index, chunk) in chunks.enumerated() {
            if reportStatus { updateStatus("Improving…", part: index + 1, total: total) }
            let messages = [
                LLMServerClient.ChatMessage(role: "system", content: resolved.systemPrompt),
                LLMServerClient.ChatMessage(role: "user", content: LLMPrompts.userMessage(for: chunk)),
            ]
            do {
                let completion = try await LLMServerClient.chat(
                    endpoint: endpoint, model: model, messages: messages, apiKey: apiKey,
                    temperature: resolved.temperature,
                    maxTokens: maxTokens(forInputChars: chunk.count)
                )
                let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    outputs.append(text)
                }
            } catch {
                if reportStatus { state.statusMessage = "" }
                if Task.isCancelled {
                    return .failed("Processing was cancelled.")
                }
                fputs("NotchWhisper: LLM server error: \(error)\n", stderr)
                return .failed(friendlyMessage(from: error, connection: connection))
            }
        }
        if reportStatus { state.statusMessage = "" }
        // Never replace dictated text with an empty result.
        if outputs.isEmpty {
            return .failed("The server returned an empty response. The original transcription was kept.")
        }
        if outputs.count == 1 {
            return .processed(outputs[0])
        }
        // Multi-chunk: modes whose result is ONE document must be re-reduced,
        // not concatenated (otherwise a long memo yields N disjoint summaries).
        // Prose modes concatenate in order.
        if resolved.reducesAcrossChunks {
            if reportStatus { state.statusMessage = "Combining \(total) parts…" }
            let messages = [
                LLMServerClient.ChatMessage(role: "system", content: resolved.reduceSystemPrompt),
                LLMServerClient.ChatMessage(
                    role: "user", content: LLMPrompts.reduceUserMessage(for: outputs)),
            ]
            if let completion = try? await LLMServerClient.chat(
                endpoint: endpoint, model: model, messages: messages, apiKey: apiKey,
                temperature: resolved.temperature,
                maxTokens: maxTokens(forInputChars: outputs.joined().count)
            ), !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if reportStatus { state.statusMessage = "" }
                return .processed(completion.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Reduce pass failed — fall back to the ordered join rather than
            // losing everything.
        }
        if reportStatus { state.statusMessage = "" }
        return .processed(outputs.joined(separator: "\n\n"))
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

    private func friendlyMessage(from error: Error, connection: LLMConnection) -> String {
        if let llmErr = error as? LLMServerError, let desc = llmErr.errorDescription {
            return desc
        }
        return "Processing failed — check that \"\(connection.name)\" is running at \(connection.endpoint) and supports OpenAI-compatible chat completions."
    }
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