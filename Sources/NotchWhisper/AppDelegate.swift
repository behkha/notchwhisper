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
    private lazy var live = LiveTranscriber(state, settings, recorder, transcriber)
    private lazy var notch = NotchController(state: state, settings: settings)
    private lazy var menuBar = MenuBarController(state: state, settings: settings)
    private lazy var llmRunner = LLMRunner(state, settings)
    private var hotkey: HotkeyMonitor?

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var isRecording = false
    /// True while a continuous live-dictation session is running (Settings →
    /// General → "Live dictation"). Distinct from `isRecording`: the live loop
    /// keeps the mic open and types as you speak until toggled off.
    private var isDictating = false
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

        // The Edit menu must contain the standard text commands: ⌘C/⌘V/⌘X/⌘A
        // are dispatched through these items' key equivalents via the responder
        // chain. An empty Edit submenu (as it was before) silently breaks
        // paste/copy in every text field — including the Local LLM settings
        // fields (API key, endpoint, model) and the custom instruction editor.
        let editMenu = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editSub = NSMenu()
        editSub.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editSub.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editSub.addItem(.separator())
        editSub.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editSub.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editSub.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editSub.addItem(.separator())
        editSub.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.submenu = editSub
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

        // Host the SwiftUI view inside an NSVisualEffectView so the whole
        // window — toolbar included — is a frosted, refractive glass surface
        // (the macOS 26 Liquid Glass look).
        let effect = NSVisualEffectView()
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                               width: Tokens.Layout.minWinW + 80,
                                               height: Tokens.Layout.minWinH + 40),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "NotchWhisper"
        win.contentView = effect
        effect.autoresizingMask = [.width, .height]
        win.applyGlassAppearance()
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

        let effect = NSVisualEffectView()
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Settings"
        win.contentView = effect
        effect.autoresizingMask = [.width, .height]
        win.applyGlassAppearance()
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
    /// Routes the hotkey by the live-dictation setting:
    ///  · OFF (default) — hold-to-talk: press-and-hold records, release transcribes.
    ///  · ON — the hotkey becomes a toggle: press once to START a continuous
    ///    live session that types as you speak, press again to STOP.
    /// Called at launch and whenever the setting (or key) changes.
    private func installHotkey() {
        if settings.liveDictation {
            hotkey = HotkeyMonitor(
                onDown: { [weak self] in Task { @MainActor in self?.toggleRecord() } },
                onUp: {},
                onPermissionNeeded: { [weak self] in
                    Task { @MainActor in self?.promptInputMonitoring() }
                }
            )
        } else {
            hotkey = HotkeyMonitor(
                onDown: { [weak self] in Task { @MainActor in self?.startRecording() } },
                onUp: { [weak self] in Task { @MainActor in self?.stopRecording() } },
                onPermissionNeeded: { [weak self] in
                    Task { @MainActor in self?.promptInputMonitoring() }
                }
            )
        }
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
        NotificationCenter.default.addObserver(forName: .dictationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Turning the feature OFF mid-session ends the live session.
                if !self.settings.liveDictation, self.isDictating {
                    self.stopDictation()
                }
                self.installHotkey()
            }
        }
    }

    func toggleRecord() {
        if isDictating { stopDictation(); return }
        if settings.liveDictation { startDictation(); return }
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !isDictating else { return }
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

    // MARK: - Live dictation (continuous, types as you speak)

    /// Starts a continuous live-dictation session. The hotkey / Record button
    /// act as a toggle while the "Live dictation" setting is ON.
    func startDictation() {
        guard !isDictating, !isRecording else { return }
        do {
            try recorder.start()
            isDictating = true
            state.mode = .dictating
            state.partialText = ""
            state.recordingStart = Date()
            beginActivity()
            if settings.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
            live.start()
        } catch {
            state.mode = .error
            state.statusMessage = "Mic unavailable: \(error.localizedDescription)"
        }
    }

    /// Stops the live session. The unconfirmed tail is flushed into the focused
    /// field, then the composed transcript lands in History.
    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        state.mode = .transcribing
        Task { await finishDictation() }
    }

    private func finishDictation() async {
        let result = await live.stop()
        // Idempotent: guarantees the mic tap is released even if the loop
        // failed to load the model mid-session (in which case stop() returns
        // early without touching the recorder).
        _ = recorder.stop()

        state.partialText = ""
        state.lastText = result.final
        guard !result.final.isEmpty else {
            endActivity()
            state.mode = .idle
            return
        }
        state.mode = .done
        endActivity()
        HistoryStore.shared.add(
            raw: result.raw,
            final: result.final,
            corrections: result.corrections,
            source: .button
        )
        // "Newline after text" re-applies at the end of a dictation session,
        // so a full paragraph is followed by a Return press.
        if settings.autoTypeEnabled, settings.insertNewline {
            AutoTyper.type("\n")
        }
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

        // 3) Optional local-LLM post-processing. The original transcription is
        // ALWAYS the fallback: any failure keeps the corrected text and the
        // user is told what happened. LLM output can never empty the field.
        var insertText = final
        var recordedLLMMode: LLMMode? = nil
        var llmFailed = false
        if settings.llmActiveForCurrentMode, !final.isEmpty {
            recordedLLMMode = settings.llmMode
            await MainActor.run {
                state.mode = .improving
                state.statusMessage = "Improving…"
            }
            let result = await llmRunner.process(final, mode: settings.llmMode)
            switch result {
            case .processed(let improved):
                if !improved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    insertText = improved
                }
            case .failed(let reason):
                llmFailed = true
                await MainActor.run {
                    state.statusMessage = "Original text inserted — LLM processing failed. \(reason)"
                }
            }
        }

        await MainActor.run {
            state.lastText = insertText
            state.partialText = ""
            // A failed LLM pass still inserts the (safe) original text, but the
            // notch/menu-bar error state communicates that processing fell back.
            if llmFailed {
                state.mode = .error
            } else {
                state.mode = insertText.isEmpty ? .idle : .done
            }
            endActivity()
            HistoryStore.shared.add(
                raw: raw, final: insertText, corrections: changes,
                source: source, llmMode: recordedLLMMode
            )
            if settings.autoTypeEnabled {
                var text = insertText
                if settings.insertNewline, !text.isEmpty { text += "\n" }
                AutoTyper.type(text)
            }
        }
    }

    // MARK: - Transcriber helpers (called from Settings UI)
    /// Download (and load) a model from Settings UI. Progress is reflected on
    /// AppState so the Settings window can show it.
    ///
    /// The model is only made active AFTER the download actually finished —
    /// selecting it earlier flipped the detail page to "Active" mid-download
    /// and a dictation started during the download would try to load a
    /// half-finished model.
    func requestDownload(modelId: String) {
        Task {
            guard await transcriber.download(modelId: modelId) else { return }
            settings.modelId = modelId
            NotificationCenter.default.post(name: .modelChanged, object: nil)
            _ = await transcriber.ensureLoaded()
        }
    }

    var transcriberRef: Transcriber { transcriber }

    // MARK: - Local LLM helpers

    var llmRunnerRef: LLMRunner { llmRunner }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
        if isDictating {
            live.cancelNow()
            isDictating = false
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}
