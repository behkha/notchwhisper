import Foundation
import Carbon
import CoreGraphics
import AppKit

/// Global "hold to talk" hotkey for right-Option (keyCode 61).
///
/// Right-Option is a *modifier* key, so it generates `flagsChanged` events,
/// NOT keyDown/keyUp. We therefore watch `flagsChanged` and look for the
/// Option-flag transition on keyCode 61.
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
    private var isDown = false

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void, onPermissionNeeded: @escaping () -> Void = {}) {
        self.onDown = onDown
        self.onUp = onUp
        self.onPermissionNeeded = onPermissionNeeded
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
            if type == .flagsChanged || type == .keyDown || type == .keyUp {
                let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if kc == monitor.keyCode {
                    if type == .flagsChanged {
                        // Modifier key: Option flag presence == pressed.
                        let pressed = event.flags.contains(.maskAlternate)
                        if pressed != monitor.isDown {
                            monitor.isDown = pressed
                            monitor.fire(pressed)
                        }
                    } else {
                        let pressed = (type == .keyDown)
                        if pressed != monitor.isDown {
                            monitor.isDown = pressed
                            monitor.fire(pressed)
                        }
                    }
                }
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

    func install(code: UInt32, carbonModifiers _: UInt32 = 0) {
        uninstall()
        keyCode = Int(code)

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
        fputs("NotchWhisper: hotkey tap installed (keyCode=\(keyCode))\n", stderr)
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
    }

    deinit { uninstall() }
}
