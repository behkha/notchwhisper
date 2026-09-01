import AppKit
import Carbon
import SwiftUI

/// Records a hotkey the way macOS shortcut fields do.
///
/// The old recorder only listened for `.keyDown`, so it could never see ⌥, ⌘,
/// ⌃ or ⇧ — those keys emit `flagsChanged` and nothing else, which is exactly
/// why "change hotkey" did nothing for them. This watches both streams and
/// supports all three shapes the monitor can arm:
///
///   · a bare modifier — tap ⌥, release, done;
///   · a modifier combination — hold ⌘, tap ⌥, release both → ⌘ + ⌥;
///   · a regular key with modifiers — hold ⌃⌥ and press Space → ⌃⌥Space.
///
/// A modifier-only gesture is committed on RELEASE, not on press: committing on
/// press would end the recording at the first ⌘ and make combinations
/// impossible to type.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Live preview of the gesture in progress ("⌘…" while ⌘ is held).
    @Published private(set) var preview = ""

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Modifier keys physically down right now (Carbon mask).
    private var heldModifiers: UInt32 = 0
    /// Every modifier seen during this gesture, including ones already released.
    private var gestureModifiers: UInt32 = 0
    /// The most recently pressed modifier key — the trigger of a modifier-only
    /// gesture.
    private var lastModifierKeyCode: Int?

    /// Called with (keyCode, Carbon modifier mask) once a gesture completes.
    var onCommit: ((UInt32, UInt32) -> Void)?

    // MARK: - Lifecycle

    func toggle() { isRecording ? cancel() : start() }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        preview = ""
        heldModifiers = 0
        gestureModifiers = 0
        lastModifierKeyCode = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // Switching away mid-gesture abandons it, so the monitor never outlives
        // the window that armed it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        isRecording = false
        preview = ""
        heldModifiers = 0
        gestureModifiers = 0
        lastModifierKeyCode = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Label for the key cap: the live gesture while recording, otherwise the
    /// stored shortcut.
    func capLabel(current: String) -> String {
        guard isRecording else { return current }
        return preview.isEmpty ? "Press a key…" : preview
    }

    // MARK: - Event handling

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:   return handleKeyDown(event)
        case .flagsChanged: return handleFlagsChanged(event)
        default:         return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        let mods = HotkeyCodes.carbon(cocoa: event.modifierFlags)
        // Escape with no modifiers abandons the recording; ⌥Esc etc. is a
        // legitimate shortcut and is recorded normally.
        if code == 53, mods == 0 {
            cancel()
            return true
        }
        commit(code: code, modifiers: mods)
        return true
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        guard HotkeyCodes.modifierKeyCodes.contains(code) else { return false }
        let mask = HotkeyCodes.carbonMask(forModifierKeyCode: code)

        if isPressed(event, keyCode: code) {
            lastModifierKeyCode = code
            heldModifiers |= mask
            gestureModifiers |= mask
            preview = Settings.hotkeyDisplay(code: UInt32(code), modifiers: gestureModifiers) + "…"
        } else {
            heldModifiers &= ~mask
            // The gesture ends when the last modifier comes back up.
            if heldModifiers == 0, let trigger = lastModifierKeyCode {
                let triggerMask = HotkeyCodes.carbonMask(forModifierKeyCode: trigger)
                commit(code: trigger, modifiers: gestureModifiers & ~triggerMask)
            }
        }
        return true
    }

    /// Whether the modifier identified by `keyCode` is down in this event.
    ///
    /// `NSEvent.modifierFlags` keeps the device-dependent left/right bits in its
    /// raw value, which is the only way to tell left ⌥ from right ⌥ when both
    /// are in play.
    private func isPressed(_ event: NSEvent, keyCode: Int) -> Bool {
        let raw = event.modifierFlags.rawValue
        if let device = Self.deviceMask(forKeyCode: keyCode) {
            return raw & device != 0
        }
        switch keyCode {
        case 57: return event.modifierFlags.contains(.capsLock)
        case 63: return event.modifierFlags.contains(.function)
        default: return false
        }
    }

    /// Device-dependent modifier bits (`NX_DEVICE*KEYMASK` from IOKit's
    /// `IOLLEvent.h`), which distinguish the left and right key of a pair.
    private static func deviceMask(forKeyCode code: Int) -> UInt? {
        switch code {
        case 59: return 0x00000001   // left ⌃
        case 62: return 0x00002000   // right ⌃
        case 56: return 0x00000002   // left ⇧
        case 60: return 0x00000004   // right ⇧
        case 55: return 0x00000008   // left ⌘
        case 54: return 0x00000010   // right ⌘
        case 58: return 0x00000020   // left ⌥
        case 61: return 0x00000040   // right ⌥
        default: return nil
        }
    }

    private func commit(code: Int, modifiers: UInt32) {
        cancel()
        onCommit?(UInt32(code), modifiers)
    }
}
