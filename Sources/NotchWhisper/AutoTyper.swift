import Foundation
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
