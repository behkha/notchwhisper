import Foundation

// MARK: - Prompts

/// System prompts. Every mode is a mode the user owns, so the only prompts
/// here are the shared rules and the wrapper that turns a mode's instructions
/// into a system prompt. The shared rules enforce the product's "preserve
/// intent" principle: never invent content, never lose dictated text. The
/// transcription arrives verbatim as the user message.
enum LLMPrompts {

    private static let sharedRules = """
    You transform dictation transcripts. Absolute rules:
    - Never invent facts, names, numbers, URLs or terminology that are not in the transcript.
    - Never add commentary, greetings, apologies or notes about what you did.
    - Keep the language of the transcript (reply in the same language).
    - Reply with the transformed text ONLY — no preamble, no quotes around it, no explanation.
    """

    /// System prompt for a user-authored mode. The user's own instructions are
    /// the task; the shared rules stay in force as a floor (never invent facts,
    /// never chat back), but where the two disagree the user wins — a mode that
    /// says "translate to German" must be allowed to override "keep the
    /// language of the transcript".
    static func systemPrompt(forCustom mode: CustomMode) -> String {
        let instructions = mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else {
            return sharedRules + "\nOutput the transcript unchanged."
        }
        return """
        \(sharedRules)
        Task: transform the dictation transcript according to the user's own \"\(name)\" mode.
        The user's instructions for this mode:
        \(instructions)

        Follow those instructions exactly. Where they conflict with the general rules above, the user's instructions win — except that you must never invent facts and never add commentary about what you did.
        """
    }

    /// Reduce pass for a custom mode marked as producing a single document.
    static func reduceSystemPrompt(forCustom mode: CustomMode) -> String {
        let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(systemPrompt(forCustom: mode))

        You are now given several partial results produced by this mode from ONE long dictation, in order. Merge them into a single coherent \"\(name)\" result: combine matching sections, keep every detail, remove duplication. Reply with the merged result only.
        """
    }

    /// Builds the user message carrying the transcript.
    static func userMessage(for transcript: String) -> String {
        "Transcript:\n\n\(transcript)"
    }

    static func reduceUserMessage(for parts: [String]) -> String {
        let joined = parts.enumerated()
            .map { "--- Part \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")
        return "Partial results:\n\n\(joined)"
    }
}
