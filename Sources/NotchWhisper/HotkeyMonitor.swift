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

/// Global "hold to talk" hotkey.
///
/// Supports three shapes of trigger:
///   · a bare modifier — e.g. right-Option (keyCode 61), the default;
///   · a modifier combination — e.g. ⌘ held + right-Option pressed;
///   · a regular key with optional modifiers — e.g. ⌃⌥Space.
///
/// Modifier keys produce `flagsChanged` events, NOT keyDown/keyUp, so the tap
/// watches all three event types and resolves "is the trigger down" from the
/// key code plus the flags carried by the event.
///
/// Permission: a keyboard CGEvent tap is Input-Monitoring-protected. We
/// explicitly request it via `CGRequestListenEventAccess()`. As a fallback we
/// also request Accessibility (`AXIsProcessTrustedWithOptions`), which covers a
/// global keyboard monitor and registers the app in System Settings reliably.
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onDown: () -> Void
    private let onUp: () -> Void
    private let onPermissionNeeded: () -> Void

    private var keyCode = 0
    /// Flags that must ALL be held for the trigger to count (empty = none).
    private var requiredFlags: CGEventFlags = []
    /// Set when the trigger key is itself a modifier — the flag it raises.
    private var triggerFlag: CGEventFlags?
    private var isDown = false

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void, onPermissionNeeded: @escaping () -> Void = {}) {
        self.onDown = onDown
        self.onUp = onUp
        self.onPermissionNeeded = onPermissionNeeded
    }

    /// True when every required modifier is present in `flags`. The trigger
    /// key's own flag is excluded from `requiredFlags`, so a bare right-Option
    /// trigger imposes no extra condition.
    private func modifiersSatisfied(_ flags: CGEventFlags) -> Bool {
        requiredFlags.isEmpty || flags.intersection(requiredFlags) == requiredFlags
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
                if let triggerFlag = monitor.triggerFlag, kc == monitor.keyCode {
                    // Modifier trigger: this event belongs to the trigger key, so
                    // its own flag tells us press vs release. The required
                    // modifiers must be held at the same instant.
                    let pressed = flags.contains(triggerFlag) && monitor.modifiersSatisfied(flags)
                    if pressed != monitor.isDown {
                        monitor.isDown = pressed
                        monitor.fire(pressed)
                    }
                } else if monitor.isDown, !monitor.modifiersSatisfied(flags) {
                    // A required modifier was let go while the trigger was held —
                    // the combination is broken, so release.
                    monitor.isDown = false
                    monitor.fire(false)
                }
            case .keyDown, .keyUp:
                guard monitor.triggerFlag == nil, kc == monitor.keyCode else { break }
                let pressed = (type == .keyDown) && monitor.modifiersSatisfied(flags)
                if pressed != monitor.isDown {
                    monitor.isDown = pressed
                    monitor.fire(pressed)
                }
            default:
                break
            }
        }
        return Unmanaged.passRetained(event)
    }

    private func fire(_ pressed: Bool) {
        if pressed { onDown() } else { onUp() }
    }

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

    func install(code: UInt32, carbonModifiers: UInt32 = 0) {
        uninstall()
        keyCode = Int(code)
        triggerFlag = HotkeyCodes.flag(forKeyCode: keyCode)
        // A modifier trigger never requires its own flag as an extra condition
        // (right-Option would otherwise mean "option + right-option").
        let ownMask = HotkeyCodes.carbonMask(forModifierKeyCode: keyCode)
        requiredFlags = HotkeyCodes.cgFlags(carbon: carbonModifiers & ~ownMask)
        isDown = false

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
        fputs("NotchWhisper: hotkey tap installed (keyCode=\(keyCode) mods=\(carbonModifiers))\n", stderr)
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
        // A pending "down" must not survive a re-install, or the next release
        // event is swallowed and recording never stops.
        if isDown {
            isDown = false
            onUp()
        }
    }

    deinit { uninstall() }
}
