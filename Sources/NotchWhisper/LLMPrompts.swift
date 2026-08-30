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

    /// Sampling temperature tuned per mode: structure-only tasks stay near
    /// deterministic (no room to invent); prose tasks get a little freedom.
    var temperature: Double {
        switch self {
        case .original:              return 0.0
        case .cleanup, .markdown:    return 0.1
        case .structured, .actions:  return 0.2
        case .rewrite, .custom:      return 0.3
        case .summarize:             return 0.4
        }
    }

    /// True when the mode's output is a single coherent document that must be
    /// re-reduced (not just concatenated) when a long transcript is chunked.
    var reducesAcrossChunks: Bool {
        switch self {
        case .summarize, .actions, .structured: return true
        default: return false
        }
    }

    /// A longer, plain-language explanation of what this mode does — shown in
    /// Settings so the user understands each choice (req 8).
    var explanation: String {
        switch self {
        case .original:
            return "No AI is used. The transcription (after dictionary fixes) is typed exactly as the speech model produced it. Fastest, fully offline, no server needed."
        case .cleanup:
            return "A light touch-up. Removes “um / uh / you know”, fixes punctuation, capitalization and obvious mis-hearings, and merges broken sentences — but keeps your exact wording and tone. Nothing is reordered or rephrased."
        case .markdown:
            return "Formatting only. Adds headings, bullet and numbered lists, checkboxes, code blocks and links where the content naturally calls for them, without changing a single word of what you said. Good for notes and docs."
        case .rewrite:
            return "Turns spoken rambling into clean written prose. Fixes grammar, drops filler and repetition, tightens sentences and organizes stray thoughts — while preserving what you meant. The wording will change."
        case .summarize:
            return "Condenses a long dictation into a short summary that keeps the key facts, decisions, names and numbers. Best for meetings or long voice memos."
        case .structured:
            return "Reorganizes free-form speech into sectioned notes (for example Topic → Key points → Decisions → Questions → Actions), choosing a structure that fits the content. Keeps all the details."
        case .actions:
            return "Scans the transcript for tasks, deadlines, follow-ups and decisions and returns them as a checklist. Says so plainly when there are none."
        case .custom:
            return "Runs your own instruction against the transcript. Write exactly what you want done — e.g. “Rewrite as a polite Slack message” or “Translate to German and format as bullet points”."
        }
    }

    /// A tiny before → after illustration for the picker.
    var example: (before: String, after: String)? {
        switch self {
        case .cleanup:
            return ("so um i think we should uh ship it on friday you know",
                    "So I think we should ship it on Friday.")
        case .markdown:
            return ("todo one fix the build two update the docs three tag the release",
                    "TODO:\n1. Fix the build\n2. Update the docs\n3. Tag the release")
        case .rewrite:
            return ("the thing is the api is slow because were calling it in a loop basically",
                    "The API is slow because we call it inside a loop.")
        case .summarize:
            return ("long update about the migration, the timeline, blockers, and who owns what…",
                    "Migration on track for Q3. Blocker: staging DB access. Owner: platform team.")
        case .actions:
            return ("remind me to email sarah and we need to book the venue before the 10th",
                    "- [ ] Email Sarah\n- [ ] Book the venue before the 10th")
        case .structured:
            return ("we talked about pricing then the launch date then bugs then next steps",
                    "## Pricing\n…\n## Launch date\n…\n## Bugs\n…\n## Next steps\n…")
        default:
            return nil
        }
    }
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

    /// Second-pass ("reduce") system prompt: merges the per-chunk outputs of a
    /// long dictation into ONE coherent document. Only used for the modes whose
    /// result is a single document (summarize / actions / structured) — for the
    /// others the per-chunk outputs are simply concatenated in order.
    static func reduceSystemPrompt(for mode: LLMMode, custom: String) -> String {
        switch mode {
        case .summarize:
            return """
            \(sharedRules)
            You are given several partial summaries of ONE long dictation, in order. Merge them into a single cohesive summary with no repetition. Keep every important fact, decision, name and number.
            """
        case .actions:
            return """
            \(sharedRules)
            You are given several partial action lists extracted from ONE long dictation, in order. Merge them into a single de-duplicated Markdown checklist. If there are genuinely no action items, say so in one line.
            """
        case .structured:
            return """
            \(sharedRules)
            You are given several partial sets of structured notes from ONE long dictation, in order. Merge them into a single well-organized document: combine sections with the same heading, keep all details, remove duplication.
            """
        default:
            return systemPrompt(for: mode, custom: custom)
        }
    }

    static func reduceUserMessage(for parts: [String]) -> String {
        let joined = parts.enumerated()
            .map { "--- Part \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")
        return "Partial results:\n\n\(joined)"
    }
}
