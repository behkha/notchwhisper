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

    /// Builds the user message carrying the transcript, plus any reference
    /// context a context-aware mode asked for.
    static func userMessage(for transcript: String, context: String? = nil) -> String {
        guard let context else { return "Transcript:\n\n\(transcript)" }
        return "Transcript:\n\n\(transcript)\n\n\(context)"
    }

    /// Reference material a mode asked for. Placed after the transcript and
    /// labelled as reference so the model resolves "this", "the above" and
    /// terminology against it without copying it into the output.
    static func contextBlock(appName: String?, selectedText: String?, clipboardText: String?) -> String? {
        var parts: [String] = []
        if let selectedText, !selectedText.isEmpty {
            let place = appName.map { " in \($0)" } ?? ""
            parts.append("Text the user has selected\(place):\n\"\"\"\n\(selectedText)\n\"\"\"")
        }
        if let clipboardText, !clipboardText.isEmpty {
            parts.append("Text on the user's clipboard:\n\"\"\"\n\(clipboardText)\n\"\"\"")
        }
        guard !parts.isEmpty else { return nil }
        return """
        Reference context. Use it to understand what the transcript refers to and to match names and terminology. Do not repeat it in your reply unless the transcript asks you to.

        \(parts.joined(separator: "\n\n"))
        """
    }

    /// The "edit selection" shortcut: the recording is an instruction, the
    /// selection is the text, and the reply replaces the selection.
    static let editSystemPrompt = """
    You edit a piece of text according to a spoken instruction. Absolute rules:
    - Apply the instruction to the text and reply with the edited text ONLY — no preamble, no quotes around it, no explanation of what changed.
    - Keep everything the instruction does not ask you to change: wording, tone, formatting, line breaks, code, names, numbers.
    - Never invent facts. Never add commentary or notes.
    - Keep the language of the text unless the instruction asks for a translation.
    - The instruction is a transcript of speech: ignore filler words and read it for intent.
    """

    static func editUserMessage(selection: String, instruction: String) -> String {
        "Instruction: \(instruction)\n\nText:\n\"\"\"\n\(selection)\n\"\"\""
    }

    static func reduceUserMessage(for parts: [String]) -> String {
        let joined = parts.enumerated()
            .map { "--- Part \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")
        return "Partial results:\n\n\(joined)"
    }
}
