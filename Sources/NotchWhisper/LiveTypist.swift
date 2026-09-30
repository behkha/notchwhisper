import AppKit
import Carbon

/// Puts live dictation on the page the way live captions update: new words
/// appear as soon as they are heard, and the words still being settled are
/// taken back with Backspace and retyped when the recognizer corrects them.
///
/// It keeps an exact model of the text it has typed in the current run —
/// `page` — and on every update types only the difference: Backspace down to
/// where the new text first differs, then the new ending. Final text is never
/// taken back, so a correction only ever touches the last few words.
///
/// Rewriting someone's document with Backspace is only safe while nothing
/// else touched it, so the run ends — and every word typed so far becomes
/// permanent — the moment the user types, clicks, or switches apps. What is
/// said after that is typed fresh at wherever the cursor now is.
@MainActor
final class LiveTypist {
    enum Style {
        /// Type as heard; correct the unsettled words in place.
        case rewrite
        /// Type each phrase once, when it is final. Never Backspace.
        case settledOnly
    }

    /// Where keystrokes go: `deleting` Backspaces, then `inserting` typed.
    /// Returns AutoTyper's diagnostic ("queued", "untrusted", "empty").
    typealias Output = @MainActor (_ deleting: Int, _ inserting: String) -> String

    let style: Style
    private let output: Output
    private let watchesUser: Bool
    /// The character just before the cursor in the target field, when it can
    /// be read — decides whether a run opens with a space.
    private let caretProbe: @MainActor () -> Character?

    /// Exactly what this run has typed and not given up.
    private(set) var page: [Character] = []
    /// Whether the page shows everything the last `render` asked for — false
    /// while typing is held back (the user took over, a modifier is down, or
    /// the field could not be checked).
    private(set) var isCurrent = true
    /// The leading part of `page` that is final text — never taken back.
    private var lockedCount = 0
    /// " " when this run follows text that needs a space before it, decided
    /// when the run types its first character.
    private var lead: String?
    private var targetApp: pid_t?
    /// The text field the run is typing into, once it has typed. Focus that
    /// moves to another field without a click or keystroke (a sheet opening,
    /// a web app refocusing) ends the run just as a click would.
    private var targetElement: AXUIElement?
    /// When the user last typed or clicked, if they have since the run began.
    private var interruptedAt: Date?
    /// Whether every interruption so far was a ⌘/⌃/⌥ shortcut — the only
    /// kind that can be the gesture that stopped the session. Plain typing
    /// and clicks change the page or the cursor, and are never forgiven.
    private var interruptionWasShortcut = true
    /// When the field last failed the look-before-deleting check, if the
    /// mismatch has not cleared since.
    private var mismatchSince: Date?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitor: Any?
    /// Whether this run may show guesses at all, decided as it starts: a
    /// field that can't be read, with the keyboard watch blind (no tap, or
    /// Secure Keyboard Entry), could never be corrected safely — such a run
    /// types final text only.
    private var runMayRewrite: Bool?
    /// Tests: typing is held back until then, as while ⌥ is still down after
    /// the default stop key.
    var holdTypingUntil: Date?

    /// `watchesUser` installs the keyboard/mouse watch that ends a run when the
    /// user takes over. Tests replaying audio into a virtual page turn it off.
    init(style: Style, watchesUser: Bool,
         caretProbe: @escaping @MainActor () -> Character? = LiveTypist.characterBeforeCaret,
         output: @escaping Output) {
        self.style = style
        self.watchesUser = watchesUser
        self.caretProbe = caretProbe
        self.output = output
    }

    /// Starts watching the user's keyboard and mouse. A listen-only event tap —
    /// the mechanism the hotkeys already rely on, under the same permission.
    /// (`NSEvent`'s global monitor was tried first: it never reported a
    /// keystroke here, only clicks.) Every event this app posts carries
    /// `AutoTyper.syntheticEventTag`, so the typist's own keystrokes never
    /// read as the user's.
    func begin() {
        targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard watchesUser, tap == nil, monitor == nil else { return }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let typist = Unmanaged<LiveTypist>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = typist.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if event.getIntegerValueField(.eventSourceUserData) != AutoTyper.syntheticEventTag {
                    typist.userEvent(type, event)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                       options: .listenOnly, eventsOfInterest: mask,
                                       callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            self.tap = tap
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // No Input Monitoring: clicks are still visible this way, keys are
            // not — `render` then only Backspaces where it can read the field.
            fputs("NotchWhisper[live]: no event tap for the user watch — watching clicks only\n", stderr)
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteInterruption(shortcut: false) }
            }
        }
    }

    /// Must be called before the typist is released: the tap holds a raw
    /// pointer to it.
    func end() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func userEvent(_ type: CGEventType, _ event: CGEvent) {
        // A click on the notch, the menu bar item or one of this app's
        // windows moves no cursor in the document.
        if type != .keyDown, Self.isOnOwnWindow(event.location) { return }
        let shortcut = type == .keyDown
            && !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        noteInterruption(shortcut: shortcut)
    }

    private func noteInterruption(shortcut: Bool) {
        // Whatever correction is on its way stops before its next keystroke.
        AutoTyper.cancelPending()
        interruptedAt = Date()
        if !shortcut { interruptionWasShortcut = false }
    }

    /// Whether a click at `location` (global display coordinates, origin top
    /// left) lands on one of this app's windows that takes clicks.
    private static func isOnOwnWindow(_ location: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let point = NSPoint(x: location.x, y: primary.frame.height - location.y)
        return NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }
    }

    /// True once the user has typed, clicked or moved to another app since the
    /// run began. The session then freezes the run and starts a new one.
    var isInterrupted: Bool {
        if interruptedAt != nil { return true }
        if watchesUser, let targetApp,
           let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != targetApp {
            noteInterruption(shortcut: false)
        }
        return interruptedAt != nil
    }

    /// How long ago the user took over, or nil if they have not.
    var interruptedFor: TimeInterval? {
        guard isInterrupted, let at = interruptedAt else { return nil }
        return Date().timeIntervalSince(at)
    }

    /// Forgets the shortcut that stopped the session at `stopAt`: a ⌘/⌃/⌥
    /// keystroke just before (or as) the stop, in the same app. It moved
    /// nothing. A click or plain typing is never forgiven — a click on this
    /// app's own notch or menu is not counted in the first place.
    func forgiveStopShortcut(at stopAt: Date) {
        guard let at = interruptedAt, interruptionWasShortcut,
              at.timeIntervalSince(stopAt) > -0.6, at.timeIntervalSince(stopAt) < 0.1,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp else { return }
        interruptedAt = nil
    }

    /// Gives up the current run: everything typed stays as it is, and typing
    /// continues from the cursor, in whichever app now has it.
    func startNewRun() {
        page = []
        lockedCount = 0
        lead = nil
        isCurrent = true
        mismatchSince = nil
        interruptedAt = nil
        interruptionWasShortcut = true
        targetElement = nil
        runMayRewrite = nil
        targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// The guess the page shows after its final text, exactly as typed.
    var guessOnPage: String { String(page.dropFirst(lockedCount)) }

    /// Brings the page to `full`, of which the first `finalText` characters are
    /// final. Returns nil when there was nothing to type, else AutoTyper's
    /// diagnostic. Types nothing while the run is interrupted or a modifier key
    /// is held (⌘ + a typed letter is a shortcut; ⌥ + Backspace deletes a word).
    @discardableResult
    func render(finalText: String, full: String) -> String? {
        var final = Array(finalText.precomposedStringWithCanonicalMapping)
        var target = final
        if style == .rewrite, runMayRewrite == nil {
            let blind = watchesUser && (tap == nil || IsSecureEventInputEnabled())
            if case .unreadable = (blind ? Self.textBeforeCaret(utf16Length: 1) : .tooShort) {
                runMayRewrite = false
                fputs("NotchWhisper[live]: this field can't be checked — typing final text only\n", stderr)
            } else {
                runMayRewrite = true
            }
        }
        if style == .rewrite, runMayRewrite == true {
            let whole = Array(full.precomposedStringWithCanonicalMapping)
            if whole.count > final.count, Array(whole[..<final.count]) == final {
                target += Array(LiveText.rewritablePrefix(String(whole[final.count...])))
            }
        }
        // A run that follows text on the same line opens with a space —
        // dictating after "Hello world." must not type "world.How".
        if lead == nil, let first = target.first(where: { !$0.isWhitespace }) {
            if let before = caretProbe(), LiveText.needsSpace(between: before, and: first) {
                lead = " "
            } else {
                lead = ""
            }
        }
        if let lead, !lead.isEmpty, !target.isEmpty {
            final = Array(lead) + final
            target = Array(lead) + target
        }

        var common = 0
        while common < page.count, common < target.count, page[common] == target[common] { common += 1 }
        if common < lockedCount {
            // Final text changed after it was typed. It is append-only, so this
            // is a bug upstream — never Backspace into final text over it.
            fputs("NotchWhisper[live]: final text diverged at \(common) < \(lockedCount); keeping the page\n", stderr)
            common = lockedCount
            target = Array(page[..<lockedCount]) + Array(target.dropFirst(lockedCount))
        }
        let deleting = page.count - common
        let inserting = String(target[common...])
        guard deleting > 0 || !inserting.isEmpty else {
            lockedCount = max(lockedCount, min(final.count, page.count))
            isCurrent = true
            return nil
        }
        isCurrent = false
        if let hold = holdTypingUntil, Date() < hold { return nil }
        guard !isInterrupted, !(watchesUser && Self.modifierHeld) else { return nil }
        if deleting > 0, watchesUser {
            guard mayDelete(String(page[common...])) else { return nil }
        }

        let result = output(deleting, inserting)
        if watchesUser, targetElement == nil { targetElement = Self.focusedElement() }
        page = target
        lockedCount = min(final.count, target.count)
        isCurrent = true
        return result
    }

    /// Look before deleting: the text before the cursor must be what this
    /// run typed, in the field it typed it into. Autocorrect may have changed
    /// it ("favourite" → "favorite"), the cursor may have moved, or focus may
    /// be in another field — Backspace counted from the model would then eat
    /// the user's characters. Keystrokes still on their way make the field
    /// look behind, so the check waits until typing has been quiet a moment,
    /// and a mismatch only counts once it has lasted.
    ///
    /// Fields that don't expose their text (terminals, most Electron views)
    /// can't be checked; they are trusted only while the keyboard watch can
    /// see the user type — not without the tap, nor under Secure Keyboard
    /// Entry, which hides keystrokes from it.
    private func mayDelete(_ doomed: String) -> Bool {
        guard let idle = AutoTyper.idleFor, idle >= 0.15 else { return false }
        if let targetElement, let now = Self.focusedElement(), !CFEqual(targetElement, now) {
            fputs("NotchWhisper[live]: focus moved to another field — keeping the page as it is\n", stderr)
            noteInterruption(shortcut: false)
            return false
        }
        let seesKeys = tap != nil && !IsSecureEventInputEnabled()
        let matches: Bool
        switch Self.textBeforeCaret(utf16Length: doomed.utf16.count) {
        case .text(let actual):
            matches = Self.comparable(actual) == Self.comparable(doomed)
        case .tooShort:
            matches = false
        case .unreadable:
            if seesKeys { mismatchSince = nil; return true }
            fputs("NotchWhisper[live]: can't read the field or watch the keyboard — keeping the page as it is\n", stderr)
            noteInterruption(shortcut: false)
            return false
        }
        if matches { mismatchSince = nil; return true }
        let since = mismatchSince ?? Date()
        mismatchSince = since
        if Date().timeIntervalSince(since) >= 0.4 {
            fputs("NotchWhisper[live]: the page changed under the typist — keeping it as it is\n", stderr)
            noteInterruption(shortcut: false)
        }
        return false
    }

    /// The character before the cursor in the focused text field, through
    /// Accessibility. nil at the start of a field, and wherever the app does
    /// not say (terminals, most Electron views) — both mean "no space".
    static func characterBeforeCaret() -> Character? {
        if case .text(let text) = textBeforeCaret(utf16Length: 1) { return text.last }
        return nil
    }

    enum CaretText {
        /// The field does not expose its text or cursor.
        case unreadable
        /// Fewer characters before the cursor than asked for.
        case tooShort
        case text(String)
    }

    /// The `utf16Length` UTF-16 units before the cursor in the focused text
    /// field. A selection counts as the cursor at its start.
    static func textBeforeCaret(utf16Length: Int) -> CaretText {
        guard utf16Length > 0, let element = focusedElement() else { return .unreadable }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unreadable }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return .unreadable }
        guard selection.location >= utf16Length else { return .tooShort }
        var probe = CFRange(location: selection.location - utf16Length, length: utf16Length)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return .unreadable }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, probeValue, &out) == .success,
              let text = out as? String else { return .unreadable }
        return .text(text)
    }

    /// The focused element of the app in front. Asked of that app's own
    /// element, whose timeout is set per object — setting one on the
    /// system-wide element would change it for every Accessibility call the
    /// app makes.
    private static func focusedElement() -> AXUIElement? {
        guard AutoTyper.isTrusted, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    /// Text as the field may legitimately hold it: the app's automatic
    /// capitals ("the" → "The" at a sentence start) and smart quotes are
    /// one-for-one substitutions and move no Backspace count.
    private static func comparable(_ text: String) -> String {
        String(text.lowercased().map { c -> Character in
            switch c {
            case "‘", "’": return "'"
            case "“", "”": return "\""
            default: return c
            }
        })
    }

    private static var modifierHeld: Bool {
        !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }
}
