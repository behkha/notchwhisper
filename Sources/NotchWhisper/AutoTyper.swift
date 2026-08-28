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
enum AutoTyper {
    /// Whether the Accessibility permission has been granted.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false
        ] as CFDictionary)
    }

    /// Types `text` into the focused target. Returns the path taken, for
    /// diagnostics: "empty", "untrusted", or "cgevent".
    @discardableResult
    static func type(_ text: String) -> String {
        guard !text.isEmpty else { return "empty" }
        guard isTrusted else { return "untrusted" }

        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            for ch in line {
                sendChars(String(ch))
                Thread.sleep(forTimeInterval: 0.001) // pacing; 1ms per char
            }
            if index < lines.count - 1 { pressReturn() }
        }
        return "cgevent"
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
