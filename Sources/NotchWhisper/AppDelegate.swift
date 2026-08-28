import AppKit
import SwiftUI
import Carbon

/// The real application delegate. NotchWhisper is now a standard macOS app:
/// a Dock icon, an app menu, a main window, and a Settings window (⌘,), plus a
/// secondary menu-bar item for status while working elsewhere. The engine layer
/// (recorder + transcriber + auto-typer) is unchanged — this file is wiring.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private let state = AppState.shared
    private let settings = Settings.shared
    private lazy var transcriber = Transcriber(state, settings)
    private lazy var recorder = AudioRecorder(state, settings)
    private lazy var notch = NotchController(state: state, settings: settings)
    private lazy var menuBar = MenuBarController(state: state, settings: settings)
    private var hotkey: HotkeyMonitor?

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var isRecording = false
    /// App Nap assertion held only while recording/transcribing, so the 60 Hz
    /// waveform timer and the audio pipeline are never throttled while the app
    /// is backgrounded. Ended as soon as we return to idle.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Dev/test hook (runs before any UI is built): if /tmp/nw_type_trigger
        // exists, type its contents into the frontmost app after 2s, write a
        // report to /tmp/nw_typeresult.txt, and exit. Exercises the production
        // AutoTyser path without touching the UI or stealing focus.
        let trigger = "/tmp/nw_type_trigger"
        if FileManager.default.fileExists(atPath: trigger),
           let text = try? String(contentsOfFile: trigger, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: trigger)
            NSApp.setActivationPolicy(.prohibited)
            let targetAtLaunch = NSWorkspace.shared.frontmostApplication
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var report = "launch=\(targetAtLaunch?.bundleIdentifier ?? "nil")"
                report += " atType=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
                let result = AutoTyper.type(text)
                try? "\(report) result=\(result)".write(toFile: "/tmp/nw_typeresult.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }

        // Dev/test hook: `--wave-preview` shows the notch pill with a simulated
        // voice waveform for ~12s so the ribbon can be screenshotted/evaluated.
        if CommandLine.arguments.contains("--wave-preview") {
            NSApp.setActivationPolicy(.prohibited)
            buildMainMenu()
            buildMainWindow()
            buildSettingsWindow()
            _ = notch
            notch.reposition()   // aim at the display holding the pointer
            state.mode = .recording
            state.recordingStart = Date()
            notch.waveform.start()
            notch.show()
            // Feed a simulated "voice" envelope: bursts of energy with pauses.
            // Also re-aim the panel at the pointer's screen every second so the
            // preview is visible no matter which display the user looks at.
            var tick = 0
            let sim = DispatchSource.makeTimerSource(queue: .main)
            sim.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            sim.setEventHandler { [weak self] in
                guard let self else { return }
                tick += 1
                let t = Double(tick) / 30.0
                if tick % 30 == 0 { self.notch.reposition() }   // follow pointer
                // Speech-like envelope: syllable bursts ~4Hz, phrase pauses.
                let syllable = 0.5 + 0.5 * sin(t * 2 * .pi * 3.7)
                let phrase = 0.5 + 0.5 * sin(t * 2 * .pi * 0.45)
                let level = Float(max(0, syllable * phrase) * 0.85)
                let levels = (0..<28).map { i -> Float in
                    let spread = 0.6 + 0.4 * sin(Double(i) * 0.5 + t * 5)
                    return level * Float(spread)
                }
                self.state.pushLevels(levels)
                // Persistent preview: runs until the app is quit (no auto-timer),
                // so it stays visible while the user inspects the notch.
            }
            sim.resume()
            return
        }

        // Background agent: stay .accessory (LSUIElement). No Dock icon — the
        // interface is the menu-bar item + the notch; windows open on demand.
        NSApp.setActivationPolicy(.accessory)

        buildMainMenu()
        buildMainWindow()
        buildSettingsWindow()

        // The notch panel stays hidden until recording starts (state-driven
        // visibility lives in NotchController) — but the controller must exist
        // so it can observe mode changes.
        _ = notch
        installHotkey()
        wireNotifications()

        // Load the model in the background so transcription is ready immediately.
        Task { _ = await transcriber.ensureLoaded() }

        // Reconcile launch-at-login with the stored setting (default ON).
        settings.applyLaunchAtLogin()

        // First run only: no local model yet → show the main window once so
        // the user can pick a model and meet the app. Afterwards the app stays
        // invisible until opened from the menu bar.
        if transcriber.availableLocalModels().isEmpty {
            showMainWindow()
        }
    }

    // MARK: - Windows
    private func buildMainMenu() {
        let main = NSMenu()
        let appName = "NotchWhisper"

        let appMenu = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appSub = NSMenu()
        appSub.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appSub.addItem(.separator())
        appSub.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        appSub.addItem(.separator())
        appSub.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenu.submenu = appSub
        main.addItem(appMenu)

        let fileMenu = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileSub = NSMenu()
        fileMenu.submenu = fileSub
        main.addItem(fileMenu)

        let editMenu = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenu.submenu = NSMenu()
        main.addItem(editMenu)

        let windowMenu = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowSub = NSMenu()
        windowSub.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowSub.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.submenu = windowSub
        main.addItem(windowMenu)

        NSApp.mainMenu = main
    }

    private func buildMainWindow() {
        let root = MainView()
            .environmentObject(state)
            .environmentObject(settings)
            .frame(minWidth: Tokens.Layout.minWinW, maxWidth: Tokens.Layout.maxWinW,
                   minHeight: Tokens.Layout.minWinH, maxHeight: Tokens.Layout.maxWinH)
        let vc = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: vc)
        win.title = "NotchWhisper"
        win.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
        win.setContentSize(NSSize(width: Tokens.Layout.minWinW + 80, height: Tokens.Layout.minWinH + 40))
        win.minSize = NSSize(width: Tokens.Layout.minWinW, height: Tokens.Layout.minWinH)
        win.center()
        win.isReleasedWhenClosed = false
        win.collectionBehavior = NSWindow.CollectionBehavior([.participatesInCycle, .managed])
        mainWindow = win
    }

    private func buildSettingsWindow() {
        let root = SettingsView()
            .environmentObject(state)
            .environmentObject(settings)
        let vc = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: vc)
        win.title = "Settings"
        win.styleMask = NSWindow.StyleMask([.titled, .closable, .resizable])
        win.setContentSize(NSSize(width: 560, height: 640))
        win.minSize = NSSize(width: 480, height: 500)
        win.isReleasedWhenClosed = false
        win.level = .normal
        settingsWindow = win
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Hotkey
    private func installHotkey() {
        hotkey = HotkeyMonitor(
            onDown: { [weak self] in Task { @MainActor in self?.startRecording() } },
            onUp: { [weak self] in Task { @MainActor in self?.stopRecording() } },
            onPermissionNeeded: { [weak self] in
                Task { @MainActor in self?.promptInputMonitoring() }
            }
        )
        // Proactively request the permission so the app registers itself in
        // System Settings (Input Monitoring, with Accessibility as a reliable
        // fallback that covers a global keyboard monitor).
        HotkeyMonitor.requestPermission()
        hotkey?.install(code: settings.hotkeyCode, carbonModifiers: settings.hotkeyModifiers)
    }

    @MainActor
    private func promptInputMonitoring() {
        // Input Monitoring is the ideal permission, but macOS only adds the app to
        // that list after a tap is attempted. Accessibility is declared too and covers
        // the same global-keyboard-event need — requesting it pops the system prompt
        // and guarantees the app appears in a privacy list. Prefer Input Monitoring
        // when available, fall back to prompting Accessibility so the user gets a gate.
        let inputURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        let axURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

        // Proactively ask for Accessibility (declared) so the OS shows a prompt and
        // registers the app — this is what makes the entry appear in System Settings.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let already = AXIsProcessTrustedWithOptions(opts)

        let alert = NSAlert()
        alert.messageText = "Enable Input Monitoring"
        alert.informativeText = already
            ? "Input Monitoring is needed for the hold-to-talk hotkey. Open System Settings, find NotchWhisper under Input Monitoring (or Accessibility), toggle it on, then relaunch NotchWhisper."
            : "NotchWhisper needs Input Monitoring (or Accessibility) to listen for the hold-to-talk hotkey. Grant it in System Settings, then relaunch NotchWhisper."
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Later")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn, let u = inputURL { NSWorkspace.shared.open(u) }
        else if resp == .alertSecondButtonReturn, let u = axURL { NSWorkspace.shared.open(u) }
    }

    private func wireNotifications() {
        NotificationCenter.default.addObserver(forName: .toggleRecord, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.toggleRecord() }
        }
        NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.hotkey?.install(code: self?.settings.hotkeyCode ?? 61,
                                  carbonModifiers: self?.settings.hotkeyModifiers ?? UInt32(optionKey))
        }
        NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in _ = await self?.transcriber.ensureLoaded() }
        }
    }

    private func toggleRecord() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording else { return }
        do {
            try recorder.start()
            isRecording = true
            state.mode = .recording
            state.recordingStart = Date()
            beginActivity()
            if settings.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        } catch {
            state.mode = .error
            state.statusMessage = "Mic unavailable: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let samples = recorder.stop()
        state.mode = .transcribing
        Task { await transcribe(samples: samples, source: .button) }
    }

    // MARK: - App Nap
    /// Hold a user-initiated activity while audio is flowing so macOS never
    /// naps/throttles us mid-recording (the app is usually backgrounded).
    private func beginActivity() {
        guard activityToken == nil else { return }
        // NSActivityUserInitiatedAllowingIdleSleep is not exposed in Swift's
        // overlay; its raw value is 0x00FFFFFF (user-initiated work that does
        // NOT block idle system sleep).
        let userInitiatedAllowingIdleSleep = ProcessInfo.ActivityOptions(rawValue: 0x00FFFFFF)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [userInitiatedAllowingIdleSleep, .latencyCritical],
            reason: "Recording and transcribing voice"
        )
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - Transcribe + dictionary passes
    private func transcribe(samples: [Float], source: TranscriptRecord.Source) async {
        guard await transcriber.ensureLoaded() else {
            await MainActor.run {
                state.mode = .error
                state.statusMessage = "Model not loaded."
                endActivity()
            }
            return
        }
        // 1) Bias the engine with short dictionary context (a nudge).
        let bias = DictionaryStore.shared.biasingTerms()
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples, biasTerms: bias)
        } catch {
            await MainActor.run {
                state.mode = .error
                state.statusMessage = "Transcription failed: \(error.localizedDescription)"
                endActivity()
            }
            return
        }
        // 2) Guaranteed correction pass (longest match first, glued words OK).
        let (final, changes) = DictionaryStore.shared.applyCorrections(raw)

        await MainActor.run {
            state.lastText = final
            state.partialText = ""
            state.mode = final.isEmpty ? .idle : .done
            endActivity()
            HistoryStore.shared.add(raw: raw, final: final, corrections: changes, source: source)
            if settings.autoTypeEnabled {
                var text = final
                if settings.insertNewline, !text.isEmpty { text += "\n" }
                AutoTyper.type(text)
            }
        }
    }

    // MARK: - Transcriber helpers (called from Settings UI)
    /// Download (and load) a model from Settings UI. Progress is reflected on
    /// AppState so the Settings window can show it.
    func requestDownload(modelId: String) {
        Task {
            settings.modelId = modelId
            await transcriber.download(modelId: modelId)
            _ = await transcriber.ensureLoaded()
        }
    }

    var transcriberRef: Transcriber { transcriber }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}
