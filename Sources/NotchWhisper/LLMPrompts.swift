import Foundation

// MARK: - Processing modes

/// What should happen to the transcription after the correction pass.
///
/// The presets are deliberately phrased as plain-language choices — the user
/// should never have to think about prompts or LLM concepts unless they pick
/// `custom`. Each mode maps to a curated system prompt in `LLMPrompts`.
enum LLMMode: String, CaseIterable, Codable, Identifiable {
    case original
    case cleanup
    case markdown
    case rewrite
    case summarize
    case structured
    case actions
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:   return "Original"
        case .cleanup:    return "Clean Up"
        case .markdown:   return "Markdown"
        case .rewrite:    return "Rewrite"
        case .summarize:  return "Summarize"
        case .structured: return "Structured Notes"
        case .actions:    return "Extract Actions"
        case .custom:     return "Custom"
        }
    }

    /// One-line explanation shown under each mode in the picker.
    var blurb: String {
        switch self {
        case .original:   return "Insert the transcription exactly as produced."
        case .cleanup:    return "Fix filler words, punctuation and obvious mistakes while keeping your voice."
        case .markdown:   return "Format into clean Markdown without changing the wording."
        case .rewrite:    return "Polish into natural written language, preserving your meaning."
        case .summarize:  return "Condense long dictations into a concise summary."
        case .structured: return "Organize free-form speech into notes with sensible sections."
        case .actions:    return "Pull out tasks, deadlines and follow-ups as an actionable list."
        case .custom:     return "Apply your own instruction to the transcription."
        }
    }

    var symbolName: String {
        switch self {
        case .original:   return "text.justify"
        case .cleanup:    return "wand.and.rays"
        case .markdown:   return "number"
        case .rewrite:    return "pencil.and.list.clipboard"
        case .summarize:  return "doc.plaintext"
        case .structured: return "list.bullet.rectangle"
        case .actions:    return "checklist"
        case .custom:     return "slider.horizontal.3"
        }
    }

    var needsCustomInstruction: Bool { self == .custom }
    /// Original = no LLM involved at all (pure passthrough).
    var isPassthrough: Bool { self == .original }
}

// MARK: - Prompts

/// System prompts for each mode. Shared rules at the top enforce the product's
/// "preserve intent" principle: never invent content, never lose dictated
/// text. The transcription arrives verbatim as the user message.
enum LLMPrompts {

    private static let sharedRules = """
    You transform dictation transcripts. Absolute rules:
    - Never invent facts, names, numbers, URLs or terminology that are not in the transcript.
    - Never add commentary, greetings, apologies or notes about what you did.
    - Keep the language of the transcript (reply in the same language).
    - Reply with the transformed text ONLY — no preamble, no quotes around it, no explanation.
    """

    /// Returns the system prompt for a mode (using the custom instruction
    /// when mode == .custom).
    static func systemPrompt(for mode: LLMMode, custom: String) -> String {
        switch mode {
        case .original:
            return sharedRules + "\nOutput the transcript unchanged."
        case .cleanup:
            return """
            \(sharedRules)
            Task: light cleanup of a dictation transcript. The speaker's wording and personality must remain intact.
            - Remove filler words ("um", "uh", "you know", "like" used as filler, repeated false starts).
            - Fix punctuation, capitalization and obvious transcription mistakes.
            - Correct clear grammatical slips and merge unnecessarily fragmented sentences.
            - Remove accidental repetitions.
            - Do NOT restructure, reorder, add headings, or otherwise rewrite the content.
            """
        case .markdown:
            return """
            \(sharedRules)
            Task: format a dictation transcript into clean Markdown WITHOUT changing the meaning or wording of the original text. Organization and formatting only.
            - Infer structure from how the content was spoken: add headings, paragraphs, bullet/numbered lists, task lists, and Markdown tables where the content naturally fits them.
            - Format code, commands, file names and URLs with the appropriate Markdown (fenced code blocks, inline code, links).
            - Use bold/italic sparingly, only where the speaker emphasized something.
            - Improve spacing and structure. Do not paraphrase: keep the original wording essentially unchanged.
            """
        case .rewrite:
            return """
            \(sharedRules)
            Task: rewrite a dictation transcript into polished written prose while preserving the speaker's intended meaning.
            - Fix grammar, remove filler words and repetition, improve sentence structure and readability.
            - Turn spoken language into natural written language and organize fragmented thoughts.
            - The result must reflect what the speaker intended to say; do not introduce new information.
            """
        case .summarize:
            return """
            \(sharedRules)
            Task: summarize a dictation transcript.
            - Focus on the important information, decisions, numbers and names rather than shortening every sentence.
            - Use short paragraphs and/or bullets as appropriate.
            """
        case .structured:
            return """
            \(sharedRules)
            Task: transform a dictation transcript into organized notes.
            - Choose a sensible structure from the content itself (for example Topic → Key points → Decisions → Questions → Actions) but stay flexible; do not force every transcript into the same template.
            - Use Markdown headings and lists. Keep all important details.
            """
        case .actions:
            return """
            \(sharedRules)
            Task: extract actionable items from a dictation transcript.
            - Produce a Markdown list of tasks, deadlines, follow-ups, decisions and important points.
            - Include the people mentioned when relevant. Only include items actually present in the transcript.
            - If the transcript contains no actionable items, reply with a single line saying so.
            """
        case .custom:
            let instruction = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = """
            \(sharedRules)
            Task: apply the user's custom instruction to the dictation transcript.
            Custom instruction from the user:
            """
            return instruction.isEmpty
                ? base + " (none provided — output the transcript unchanged)"
                : base + "\n" + instruction
        }
    }

    /// Builds the user message carrying the transcript.
    static func userMessage(for transcript: String) -> String {
        "Transcript:\n\n\(transcript)"
    }
}
