import Foundation
import AppKit
import ApplicationServices
import Carbon

/// Types text into whichever target currently has keyboard focus by posting
/// synthetic keyboard events that carry Unicode strings — i.e. what a real
/// keyboard does. Works everywhere (terminals included: Terminal.app, iTerm,
/// Warp accept keystrokes but ignore AXUIElement value-writes on their content
/// view). Layout-independent and case-correct.
///
/// Note: the previous design preferred AX value-insertion and only fell back
/// to keystrokes. That broke terminals silently: setting kAXValue on
/// Terminal's text area "succeeds" but edits the on-screen buffer without
/// sending anything to the pty, so the shell never saw the text.
///
/// Threading: the actual keystroke loop (with its per-character pacing sleep)
/// runs on a private SERIAL queue, never the caller's thread. Callers are on
/// the MainActor — a synchronous 1 ms-per-char sleep there froze the UI and
/// the live-dictation tick loop for the duration of every inserted phrase.
/// The serial queue also guarantees deltas are typed in the order enqueued.
enum AutoTyper {
    /// Whether the Accessibility permission has been granted.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false
        ] as CFDictionary)
    }

    private static let queue = DispatchQueue(label: "com.behkha.notchwhisper.autotyper", qos: .userInitiated)

    /// How text reaches the target.
    ///
    /// `keystrokes` is the default and works everywhere. `paste` exists for
    /// terminal programs — Claude Code, Codex, a REPL — where per-character
    /// synthetic typing is actively wrong:
    ///  · every "\n" is a Return, which SUBMITS the line instead of writing it,
    ///    so a two-sentence dictation is sent as two half-messages;
    ///  · shell completion and history bindings fire on the keystrokes;
    ///  · hundreds of events at 1 ms each are slow and droppable.
    /// A paste arrives as one bracketed-paste block: newlines stay literal and
    /// nothing is submitted until the user presses Return themselves.
    enum InsertionMode: String, Codable, CaseIterable, Identifiable {
        case keystrokes
        case paste

        var id: String { rawValue }

        var label: String {
            switch self {
            case .keystrokes: return "Type it"
            case .paste:      return "Paste it"
            }
        }

        var blurb: String {
            switch self {
            case .keystrokes:
                return "Sends the text as keystrokes. Works in every app."
            case .paste:
                return "Puts the text on the clipboard and presses ⌘V, then restores what was there. Best for terminal tools, where a newline would submit the line."
            }
        }
    }

    /// Single entry point used by the dictation pipeline.
    @discardableResult
    static func insert(_ text: String, mode: InsertionMode) -> String {
        switch mode {
        case .keystrokes: return type(text)
        case .paste:      return paste(text)
        }
    }

    /// Enqueues a clipboard paste of `text`. Returns immediately; the ⌘V is
    /// ordered against pending typing on the same serial queue.
    ///
    /// The pasteboard is written HERE, on the caller's thread, and restored on
    /// the main queue after the paste — never with `DispatchQueue.main.sync`
    /// from the typing queue, which deadlocks outright any time the main thread
    /// is blocked (it silently ate the first end-to-end test of this path).
    @discardableResult
    static func paste(_ text: String) -> String {
        guard !text.isEmpty else { return "empty" }
        guard isTrusted else { return "untrusted" }
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        queue.async {
            pressCommandV()
            // The target reads the clipboard asynchronously after the
            // keystroke, so the restore has to wait for it to have pasted.
            Thread.sleep(forTimeInterval: 0.25)
            DispatchQueue.main.async { restorePasteboard(pasteboard, from: saved) }
        }
        return "queued"
    }

    /// Enqueues `text` to be typed into the focused target. Returns immediately.
    /// The returned path is for diagnostics: "empty", "untrusted", or "queued".
    /// (Trust is re-checked on the queue right before typing too, so a grant
    /// made between enqueue and execution still works.)
    @discardableResult
    static func type(_ text: String) -> String {
        guard !text.isEmpty else { return "empty" }
        guard isTrusted else { return "untrusted" }
        queue.async { typeNow(text) }
        return "queued"
    }

    /// Synchronous variant for the one-shot CLI/test entry points (`main.swift`
    /// `--type-test`), where blocking is fine and the process exits right after.
    @discardableResult
    static func typeBlocking(_ text: String) -> String {
        guard !text.isEmpty else { return "empty" }
        guard isTrusted else { return "untrusted" }
        typeNow(text)
        return "cgevent"
    }

    private static func typeNow(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            for ch in line {
                sendChars(String(ch))
                Thread.sleep(forTimeInterval: 0.001) // pacing; 1ms per char
            }
            if index < lines.count - 1 { pressReturn() }
        }
    }

    // MARK: - Clipboard paste

    /// The restore is best effort by design: it copies every representation of
    /// every item it finds, but a promised/lazy item (a file drag, another
    /// app's custom type) cannot be captured. The user's clipboard is borrowed
    /// for roughly a quarter of a second, and the UI says so rather than
    /// letting them discover it.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { representations[type] = data }
            }
            return representations
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard,
                                          from saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.compactMap { representations in
            guard !representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func pressCommandV() {
        // Setting `.maskCommand` on the V event alone is NOT enough: targets
        // that track modifier state from the event stream (Terminal among them)
        // see a V with no preceding ⌘ press and paste nothing. The physical
        // sequence — ⌘ down, V down, V up, ⌘ up — is what works.
        let source = CGEventSource(stateID: .combinedSessionState)
        let command: CGKeyCode = 55   // kVK_Command
        let v: CGKeyCode = 9          // kVK_ANSI_V

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }

        post(command, down: true, flags: .maskCommand)
        post(v, down: true, flags: .maskCommand)
        post(v, down: false, flags: .maskCommand)
        post(command, down: false, flags: [])
    }

    // MARK: - Synthetic keystrokes (Unicode-string events)

    private static func pressReturn() {
        CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func sendChars(_ str: String) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: str.utf16.count, unicodeString: Array(str.utf16))
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: str.utf16.count, unicodeString: Array(str.utf16))
        up?.post(tap: .cghidEventTap)
    }
}
