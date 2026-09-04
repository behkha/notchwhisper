import Foundation
import Carbon
import CoreGraphics
import AppKit

/// Maps between the three key/modifier vocabularies the app has to speak:
/// Carbon modifier masks (what `Settings` persists), `CGEventFlags` (what the
/// event tap sees) and `NSEvent.ModifierFlags` (what the recorder in Settings
/// receives).
enum HotkeyCodes {
    /// Key codes that ARE modifiers — pressing one produces `flagsChanged`,
    /// never `keyDown`. Left and right variants are distinct codes.
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// The flag a modifier key raises when it is held. `nil` for regular keys.
    static func flag(forKeyCode code: Int) -> CGEventFlags? {
        switch code {
        case 54, 55:  return .maskCommand      // right ⌘, left ⌘
        case 56, 60:  return .maskShift        // left ⇧, right ⇧
        case 58, 61:  return .maskAlternate    // left ⌥, right ⌥
        case 59, 62:  return .maskControl      // left ⌃, right ⌃
        case 57:      return .maskAlphaShift   // caps lock
        case 63:      return .maskSecondaryFn  // fn
        default:      return nil
        }
    }

    /// Carbon modifier mask → the CGEventFlags the tap must see.
    static func cgFlags(carbon mods: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods & UInt32(cmdKey) != 0     { flags.insert(.maskCommand) }
        if mods & UInt32(shiftKey) != 0   { flags.insert(.maskShift) }
        if mods & UInt32(optionKey) != 0  { flags.insert(.maskAlternate) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        return flags
    }

    /// Cocoa modifier flags (from an `NSEvent`) → the Carbon mask we persist.
    static func carbon(cocoa flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    /// The Carbon mask a modifier KEY contributes, so a trigger key is never
    /// also listed among its own required modifiers.
    static func carbonMask(forModifierKeyCode code: Int) -> UInt32 {
        switch code {
        case 54, 55: return UInt32(cmdKey)
        case 56, 60: return UInt32(shiftKey)
        case 58, 61: return UInt32(optionKey)
        case 59, 62: return UInt32(controlKey)
        default:     return 0
        }
    }
}

/// Global hotkey table.
///
/// Supports three shapes of trigger, any number of times over:
///   · a bare modifier — e.g. right-Option (keyCode 61), the default;
///   · a modifier combination — e.g. ⌘ held + right-Option pressed;
///   · a regular key with optional modifiers — e.g. ⌃⌥Space.
///
/// Modifier keys produce `flagsChanged` events, NOT keyDown/keyUp, so the tap
/// watches all three event types and resolves "is this trigger down" from the
/// key code plus the flags carried by the event.
///
/// ONE tap serves every binding. The per-binding state is a table; at most one
/// trigger is ever active, because there is one microphone.
///
/// Permission: a keyboard CGEvent tap is Input-Monitoring-protected. We
/// explicitly request it via `CGRequestListenEventAccess()`. As a fallback we
/// also request Accessibility (`AXIsProcessTrustedWithOptions`), which covers a
/// global keyboard monitor and registers the app in System Settings reliably.
final class HotkeyMonitor {
    /// One installed shortcut. Plain data so the whole table can be dumped.
    struct Trigger {
        let id: UUID
        let name: String
        let keyCode: Int
        /// Flags that must ALL be held for the trigger to count (empty = none).
        let requiredFlags: CGEventFlags
        /// Set when the trigger key is itself a modifier — the flag it raises.
        let triggerFlag: CGEventFlags?
        var isDown = false

        var specificity: Int { requiredFlags.rawValue.nonzeroBitCount }
        /// A bare modifier fires the instant its key goes down, which is why it
        /// is the one shape that needs debouncing.
        var isBareModifier: Bool { triggerFlag != nil && requiredFlags.isEmpty }
    }

    /// A bare modifier raises its flag before any combination containing it can
    /// complete, and `flagsChanged` for ⌃ arrives before ⌥ in some orders. Hold
    /// a bare-modifier trigger this long before committing to it, so a more
    /// specific trigger that is still being typed gets to win.
    private static let bareModifierDebounce: TimeInterval = 0.040

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onDown: (UUID) -> Void
    private let onUp: (UUID) -> Void
    private let onPermissionNeeded: () -> Void

    /// Sorted most-specific FIRST, so `⌃⌥D` is matched before a bare `D`.
    private(set) var triggers: [Trigger] = []
    /// The session in flight. At most one — one microphone, one session.
    private var activeTrigger: UUID?
    /// A bare-modifier trigger waiting out the debounce window.
    private var pendingTrigger: UUID?
    /// Invalidates a scheduled debounce that has been superseded.
    private var pendingToken = 0

    init(onDown: @escaping (UUID) -> Void,
         onUp: @escaping (UUID) -> Void,
         onPermissionNeeded: @escaping () -> Void = {}) {
        self.onDown = onDown
        self.onUp = onUp
        self.onPermissionNeeded = onPermissionNeeded
    }

    /// True when every required modifier is present in `flags`. The trigger
    /// key's own flag is excluded from `requiredFlags`, so a bare right-Option
    /// trigger imposes no extra condition.
    private func satisfied(_ trigger: Trigger, _ flags: CGEventFlags) -> Bool {
        trigger.requiredFlags.isEmpty
            || flags.intersection(trigger.requiredFlags) == trigger.requiredFlags
    }

    // Plain C callback (no captured context). Reads state via the `userInfo` refcon.
    private let callback: CGEventTapCallBack = { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
        // macOS disables event taps after a timeout or user input — re-enable
        // immediately so the hotkey keeps working while the app is backgrounded.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let refcon {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if let tap = monitor.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    fputs("NotchWhisper: event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")\n", stderr)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if let refcon {
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let flags = event.flags
            let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
            switch type {
            case .flagsChanged:
                monitor.evaluate(keyCode: kc, flags: flags, keyEvent: nil)
            case .keyDown:
                monitor.evaluate(keyCode: kc, flags: flags, keyEvent: true)
            case .keyUp:
                monitor.evaluate(keyCode: kc, flags: flags, keyEvent: false)
            default:
                break
            }
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - Resolution
    //
    // Runs on the main run loop (the tap source is attached to it), so all of
    // this state — including the debounce timer — is single-threaded.

    /// Test hook: feeds one synthetic event through exactly the resolution the
    /// tap callback uses. `--hotkey-selftest` drives the table with these
    /// instead of posting real CGEvents, which need Input Monitoring, a focused
    /// target, and a machine nobody is typing on.
    func simulate(keyCode: Int, flags: CGEventFlags, keyEvent: Bool? = nil) {
        evaluate(keyCode: keyCode, flags: flags, keyEvent: keyEvent)
    }

    /// `keyEvent` is nil for `flagsChanged`, true for `keyDown`, false for `keyUp`.
    private func evaluate(keyCode kc: Int, flags: CGEventFlags, keyEvent: Bool?) {
        // Pass 1 — releases. Every trigger that lost its key or a required
        // modifier goes up, whether or not it is the active one.
        for i in triggers.indices where triggers[i].isDown {
            guard let pressed = pressedState(triggers[i], keyCode: kc, flags: flags, keyEvent: keyEvent),
                  pressed == false else { continue }
            release(index: i)
        }

        // Pass 2 — presses. `triggers` is sorted most-specific first, so the
        // first match in this order is the most specific one that fits.
        for i in triggers.indices where !triggers[i].isDown {
            guard let pressed = pressedState(triggers[i], keyCode: kc, flags: flags, keyEvent: keyEvent),
                  pressed else { continue }
            press(index: i)
            break
        }
    }

    /// The trigger's new pressed state, or nil when this event says nothing
    /// about it.
    private func pressedState(_ trigger: Trigger, keyCode kc: Int,
                              flags: CGEventFlags, keyEvent: Bool?) -> Bool? {
        if let triggerFlag = trigger.triggerFlag {
            // Modifier trigger: an event for its own key carries press/release
            // in the flag it raises.
            if keyEvent == nil, kc == trigger.keyCode {
                return flags.contains(triggerFlag) && satisfied(trigger, flags)
            }
        } else if let keyDown = keyEvent, kc == trigger.keyCode {
            return keyDown && satisfied(trigger, flags)
        }
        // Any other event can only BREAK a held combination: a required
        // modifier was let go while the trigger was down.
        if trigger.isDown, !satisfied(trigger, flags) { return false }
        return nil
    }

    private func press(index i: Int) {
        // One session at a time. Another trigger going down while one is active
        // is ignored, and deliberately NOT recorded as down — otherwise its
        // release would fire a stray "up".
        guard activeTrigger == nil else { return }

        triggers[i].isDown = true
        let id = triggers[i].id

        if triggers[i].isBareModifier, needsDebounce(index: i) {
            pendingTrigger = id
            pendingToken &+= 1
            let token = pendingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bareModifierDebounce) { [weak self] in
                self?.commitPending(token)
            }
            return
        }

        // A more specific trigger completed inside the debounce window — the
        // bare modifier that was waiting loses, without ever having fired.
        if pendingTrigger != nil { cancelPending() }
        activeTrigger = id
        onDown(id)
    }

    private func release(index i: Int) {
        triggers[i].isDown = false
        let id = triggers[i].id
        if pendingTrigger == id {
            // Released inside the debounce window: nothing more specific ever
            // arrived, so honour the press as a (very short) one, exactly as an
            // undebounced trigger would have.
            cancelPending()
            activeTrigger = id
            onDown(id)
            activeTrigger = nil
            onUp(id)
            return
        }
        guard activeTrigger == id else { return }
        activeTrigger = nil
        onUp(id)
    }

    /// True when some other trigger could still win this keystroke: another
    /// binding on the same key that wants modifiers, or any binding that
    /// requires the very modifier this bare trigger raises.
    private func needsDebounce(index i: Int) -> Bool {
        let trigger = triggers[i]
        guard let flag = trigger.triggerFlag else { return false }
        return triggers.contains { other in
            guard other.id != trigger.id else { return false }
            if other.keyCode == trigger.keyCode, !other.requiredFlags.isEmpty { return true }
            return other.requiredFlags.contains(flag)
        }
    }

    private func commitPending(_ token: Int) {
        guard token == pendingToken, let id = pendingTrigger, activeTrigger == nil,
              let i = triggers.firstIndex(where: { $0.id == id }), triggers[i].isDown
        else { return }
        pendingTrigger = nil
        activeTrigger = id
        onDown(id)
    }

    private func cancelPending() {
        pendingTrigger = nil
        pendingToken &+= 1
    }

    // MARK: - Permission

    /// Returns true if the OS currently grants the needed permission.
    static var hasPermission: Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightListenEventAccess() { return true }
        }
        return AXIsProcessTrusted()
    }

    /// Ask the OS for permission (shows the system prompt / registers the app).
    static func requestPermission() {
        if #available(macOS 10.15, *) {
            _ = CGRequestListenEventAccess()
        }
        // Accessibility fallback also covers a global keyboard monitor and
        // reliably registers the app in System Settings.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Install

    /// Builds the trigger table WITHOUT touching the event tap. Split out so
    /// `--hotkey-dump` can print exactly what would be installed, headless and
    /// with no permission.
    func installTableOnly(_ bindings: [HotkeyBinding]) {
        triggers = bindings
            .filter { $0.keyCode != 0 }
            .map {
                Trigger(id: $0.id, name: $0.name, keyCode: Int($0.keyCode),
                        requiredFlags: $0.requiredFlags, triggerFlag: $0.triggerFlag)
            }
            // Most specific first: `evaluate` takes the first match.
            .sorted { $0.specificity > $1.specificity }
    }

    /// Arms the whole table. One tap, one `CGEventMask`, however many bindings.
    func install(_ bindings: [HotkeyBinding]) {
        uninstall()
        installTableOnly(bindings)

        guard !triggers.isEmpty else {
            fputs("NotchWhisper: no hotkey bindings enabled — tap not installed\n", stderr)
            return
        }

        // Listen to both modifier transitions and plain key events.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("NotchWhisper: CGEvent tap FAILED — permission missing\n", stderr)
            DispatchQueue.main.async { self.onPermissionNeeded() }
            return
        }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        fputs("NotchWhisper: hotkey tap installed — \(triggers.count) trigger(s)\n\(dump())", stderr)
    }

    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        cancelPending()
        // A pending "down" must not survive a re-install, or the next release
        // event is swallowed and recording never stops.
        if let id = activeTrigger {
            activeTrigger = nil
            onUp(id)
        }
        for i in triggers.indices { triggers[i].isDown = false }
    }

    /// The installed table, one line per trigger — what `--hotkey-dump` prints.
    func dump() -> String {
        triggers.map { t in
            let mods = HotkeyMonitor.flagNames(t.requiredFlags)
            let own = t.triggerFlag.map { HotkeyMonitor.flagNames($0) } ?? "—"
            return "  keyCode=\(t.keyCode) requires=\(mods) ownFlag=\(own) specificity=\(t.specificity)  \(t.name)\n"
        }.joined()
    }

    static func flagNames(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl)     { parts.append("⌃") }
        if flags.contains(.maskAlternate)   { parts.append("⌥") }
        if flags.contains(.maskShift)       { parts.append("⇧") }
        if flags.contains(.maskCommand)     { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        if flags.contains(.maskAlphaShift)  { parts.append("caps") }
        return parts.isEmpty ? "none" : parts.joined()
    }

    deinit { uninstall() }
}
