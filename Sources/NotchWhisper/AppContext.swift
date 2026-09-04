import AppKit
import ApplicationServices

/// Where a dictation is going: which app has focus, and what kind of field.
///
/// Captured ONCE, at recording start — the user chooses the destination by
/// looking at it and pressing the hotkey, so an app switch mid-dictation must
/// not change the writing style of the sentence already being spoken.
///
/// This is shared plumbing. App profiles read it today; per-app privacy rules
/// and voice revisions will read the same type. Extend it here rather than
/// growing a second frontmost-app helper elsewhere.
struct AppContext: Equatable {
    /// Bundle identifier of the frontmost app, e.g. "com.tinyspeck.slackmacgap".
    var bundleID: String?
    /// Localized app name, for display only.
    var appName: String?
    /// What the focused element looks like, when Accessibility can tell us.
    var fieldRole: FieldRole = .unknown
    /// The focused field is a password field. Best effort: several apps do not
    /// expose the role at all, so `false` never means "definitely not secure".
    var isSecureField: Bool = false
    /// Title of the focused window. Terminals put the running command and the
    /// working directory here, which is how a tab is told apart from its
    /// siblings; other apps often name the document.
    var windowTitle: String?
    /// The command-line program in front INSIDE a terminal — "claude", "codex",
    /// "vim", or the shell's own name when nothing else is running. nil when
    /// the destination is not a terminal, or the tool could not be resolved.
    var cliTool: String?
    /// The resolved `cliTool` is a bare shell prompt, not a program.
    var cliToolIsShell: Bool = false

    enum FieldRole: String, Equatable {
        case text, search, secure, terminal, unknown
    }

    /// No known destination — the desktop, a Space transition, or a build with
    /// no Accessibility grant. Callers fall back to global settings.
    static let empty = AppContext()

    var isEmpty: Bool { bundleID == nil }

    /// NotchWhisper's own windows never match an app profile.
    var isSelf: Bool { bundleID != nil && bundleID == Bundle.main.bundleIdentifier }

    var displayName: String { appName ?? bundleID ?? "Unknown app" }

    /// "Terminal · claude" — what the user should see attributed in the UI.
    var targetName: String {
        guard let cliTool, !cliTool.isEmpty else { return displayName }
        return "\(displayName) · \(cliTool)"
    }

    var isTerminal: Bool { fieldRole == .terminal }

    /// Terminals are recognised by bundle id, not by AX role: they expose an
    /// ordinary text area, and the distinction matters because typing a newline
    /// into one EXECUTES the line.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
    ]

    // MARK: - Capture

    /// Reads the current destination. Cheap (one AX round trip, bounded by a
    /// 250 ms messaging timeout) and never throws — an unreadable element
    /// degrades to `.unknown`, it does not fail the dictation.
    @MainActor
    static func current() -> AppContext {
        var context = AppContext()
        if let app = NSWorkspace.shared.frontmostApplication {
            context.bundleID = app.bundleIdentifier
            context.appName = app.localizedName
        }
        if let bundleID = context.bundleID, terminalBundleIDs.contains(bundleID) {
            context.fieldRole = .terminal
        }
        // The AX query needs the same Accessibility grant AutoTyper needs, so
        // asking without it only produces a permission prompt we did not want.
        guard AutoTyper.isTrusted else { return context }

        // Inside a terminal, the app identity is not the whole story: Claude
        // Code, Codex and a bare shell prompt are all "Terminal". Resolve the
        // foreground program so a profile can target the tool, not the window.
        if context.fieldRole == .terminal,
           let app = NSWorkspace.shared.frontmostApplication {
            context.windowTitle = focusedWindowTitle(pid: app.processIdentifier)
            if let tool = TerminalProcess.focusedTool(terminalPID: app.processIdentifier,
                                                     windowTitle: context.windowTitle) {
                context.cliTool = tool.name
                context.cliToolIsShell = tool.isShell
            }
        }

        guard let element = focusedElement() else { return context }

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        context.isSecureField = secure

        if secure {
            context.fieldRole = .secure
        } else if context.fieldRole != .terminal {
            switch (role, subrole) {
            case (_, "AXSearchField"):                     context.fieldRole = .search
            case ("AXTextField", _), ("AXTextArea", _):    context.fieldRole = .text
            case ("AXComboBox", _):                        context.fieldRole = .text
            default:                                       context.fieldRole = .unknown
            }
        }
        return context
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // Without a timeout a hung app blocks the hotkey path itself.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Title of the frontmost window of `pid`, via that app's AX element.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return string((window as! AXUIElement), kAXTitleAttribute)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    // MARK: - Diagnostics

    /// One-line summary for the `--app-context` self-test and toasts.
    var debugSummary: String {
        var line = "app=\(bundleID ?? "—") name=\(appName ?? "—") field=\(fieldRole.rawValue) secure=\(isSecureField)"
        if let cliTool { line += " cli=\(cliTool)\(cliToolIsShell ? " (shell)" : "")" }
        if let windowTitle { line += " title=\"\(windowTitle)\"" }
        return line
    }
}
