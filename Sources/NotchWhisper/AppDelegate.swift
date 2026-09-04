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
    private var updateWindow: NSWindow?
    private var hubWindow: NSWindow?

    private var isRecording = false
    /// True while a continuous live-dictation session is running (Settings →
    /// General → "Live dictation"). Distinct from `isRecording`: the live loop
    /// keeps the mic open and types as you speak until toggled off.
    private var isDictating = false
    /// A dictation start is parked waiting for the model to finish loading.
    private var awaitingModelForDictation = false
    /// True from `stopDictation()` until `finishDictation()` has fully released
    /// the mic. Teardown is async (a final decode runs before `recorder.stop()`),
    /// and `isDictating` is already false during it — without this guard a
    /// hold-to-talk press in that window starts a SECOND recorder session on the
    /// shared `AudioRecorder`, which the live teardown then rips out mid-phrase
    /// (the "types as I speak, then types the whole thing again" bug).
    private var isFinishingDictation = false
    /// Where the CURRENT dictation is going, captured when the mic opened.
    /// The user chooses a destination by looking at it and pressing the key, so
    /// an app switch mid-dictation must not change how the sentence is written.
    private var pendingContext = AppContext.empty
    /// Settings for the current dictation after the matching app profile had
    /// its say. Resolved once, so nothing can change under a recording.
    private var pendingEffective: EffectiveSettings?
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
                let result = AutoTyper.typeBlocking(text)
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
        // The menu-bar item is the ONLY way to reach the main window / Settings
        // once first run is over (no Dock icon in .accessory mode). It's a lazy
        // var, so it must be touched here or it never gets created — which is
        // exactly what was happening: no status item ever appeared.
        _ = menuBar
        installHotkey()
        wireNotifications()

        // Bring up the model registry (reconciles the installed-model records
        // against what is actually on disk) before anything reads from it.
        _ = ModelRegistry.shared

        // Load the model in the background so transcription is ready
        // immediately — unless the user chose to defer it until first use.
        if settings.modelPreload.preloadsAtLaunch {
            Task { _ = await transcriber.ensureLoaded() }
        }

        // Reconcile launch-at-login with the stored setting (default ON).
        settings.applyLaunchAtLogin()

        // Ask GitHub whether `main` moved on since this build's commit. Delayed
        // so it never competes with model loading at launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            UpdateChecker.shared.checkAtLaunch()
        }

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
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        appSub.addItem(updateItem)
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

    /// Shared window chrome for the bespoke Aurora windows: full-bleed dark,
    /// transparent titlebar, no title text — SwiftUI paints everything.
    private func makeAuroraWindow(_ root: some View, width: CGFloat, height: CGFloat,
                                  minW: CGFloat, minH: CGFloat, title: String) -> NSWindow {
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = title
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.055, alpha: 1)
        win.isOpaque = true
        win.contentView = hosting
        hosting.autoresizingMask = [.width, .height]
        win.setContentSize(NSSize(width: width, height: height))
        win.minSize = NSSize(width: minW, height: minH)
        win.center()
        win.isReleasedWhenClosed = false
        return win
    }

    private func buildMainWindow() {
        let root = MainView()
            .environmentObject(state)
            .environmentObject(settings)
        let win = makeAuroraWindow(root,
                                   width: Tokens.Layout.minWinW + 80, height: Tokens.Layout.minWinH + 40,
                                   minW: Tokens.Layout.minWinW, minH: Tokens.Layout.minWinH,
                                   title: "NotchWhisper")
        win.collectionBehavior = NSWindow.CollectionBehavior([.participatesInCycle, .managed])
        mainWindow = win
    }

    private func buildSettingsWindow() {
        let root = SettingsView()
            .environmentObject(state)
            .environmentObject(settings)
        let win = makeAuroraWindow(root, width: 620, height: 720, minW: 560, minH: 560,
                                   title: "Settings")
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

    /// The Updates window. Built on demand — most launches never open it.
    @objc func showUpdates() {
        if updateWindow == nil {
            let win = makeAuroraWindow(UpdateView(), width: 620, height: 620,
                                       minW: 560, minH: 460, title: "Updates")
            win.level = .normal
            updateWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.makeKeyAndOrderFront(nil)
    }

    /// The Hugging Face browser. A window rather than a sheet: browsing the Hub
    /// is open-ended, and a macOS SwiftUI sheet can't be resized by the user.
    /// Built on demand — most sessions never open it.
    @objc func showHubBrowser() {
        if hubWindow == nil {
            let root = HubBrowserWindow()
                .environmentObject(state)
                .environmentObject(settings)
            // The minimums match the browser view's own frame, so dragging the
            // window small can never clip its search controls.
            let win = makeAuroraWindow(root, width: 1100, height: 820,
                                       minW: 780, minH: 600, title: "Hugging Face")
            win.level = .normal
            hubWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    /// Menu command: check, then open the window with whatever came back.
    @objc func checkForUpdates() {
        UpdateChecker.shared.check()
        showUpdates()
    }

    // MARK: - Hotkey
    /// Arms every enabled binding on ONE event tap. Each binding carries its own
    /// activation:
    ///  · holdToTalk — press-and-hold records, release transcribes;
    ///  · toggleLive — press once to START a continuous live session that types
    ///    as you speak, press again to STOP.
    /// Called at launch, whenever the table changes, and defensively on wake.
    private func installHotkey() {
        hotkey = HotkeyMonitor(
            onDown: { [weak self] id in Task { @MainActor in self?.hotkeyDown(id) } },
            onUp:   { [weak self] id in Task { @MainActor in self?.hotkeyUp(id) } },
            onPermissionNeeded: { [weak self] in
                Task { @MainActor in self?.promptInputMonitoring() }
            }
        )
        // Proactively request the permission so the app registers itself in
        // System Settings (Input Monitoring, with Accessibility as a reliable
        // fallback that covers a global keyboard monitor).
        HotkeyMonitor.requestPermission()
        hotkey?.install(HotkeyBindingStore.shared.installable)
    }

    /// A binding asking for a live session on a model that cannot stream falls
    /// back to hold-to-talk. Same rule `reconcileAfterModelChange()` has always
    /// applied to the single hotkey, now decided per binding.
    func activation(for binding: HotkeyBinding) -> HotkeyBinding.Activation {
        binding.effectiveActivation == .toggleLive && canStreamLive ? .toggleLive : .holdToTalk
    }

    private func hotkeyDown(_ id: UUID) {
        guard let binding = HotkeyBindingStore.shared.binding(id: id) else { return }
        switch activation(for: binding) {
        case .toggleLive: trigger(binding: binding)
        case .holdToTalk: startRecording(binding: binding)
        }
    }

    private func hotkeyUp(_ id: UUID) {
        // A live-session binding is a toggle — its release means nothing. The
        // binding is looked up again rather than remembered, so a table edit
        // mid-press can never strand a recording.
        guard let binding = HotkeyBindingStore.shared.binding(id: id),
              activation(for: binding) == .holdToTalk else { return }
        stopRecording()
    }

    @MainActor
    func promptInputMonitoring() {
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
            Task { @MainActor in
                self?.hotkey?.install(HotkeyBindingStore.shared.installable)
            }
        }
        // "Hotkey dead after the lid opened": the tap usually survives sleep and
        // the disable path covers the rest, but re-arming on wake is cheap and
        // removes a whole class of report.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installHotkey() }
        }
        NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A llama:* model can't stream — end any running live session,
                // whichever key started it. Every toggleLive binding falls back
                // to hold-to-talk while that model is active.
                if !self.canStreamLive, self.isDictating { self.stopDictation() }
                _ = await self.transcriber.ensureLoaded()
            }
        }
        NotificationCenter.default.addObserver(forName: .openHubBrowser, object: nil,
                                               queue: .main) { [weak self] note in
            let seed = (note.object as? String) ?? ""
            Task { @MainActor in
                HubBrowserOpener.shared.request(seed: seed)
                self?.showHubBrowser()
            }
        }
        NotificationCenter.default.addObserver(forName: .dictationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Turning the global switch OFF ends any live session the
                // switch itself is holding up: the Record button's, and a
                // shortcut's if that shortcut inherits its activation (it just
                // became hold-to-talk, so pressing it again would no longer
                // stop the session). A shortcut that PINNED "Live session" is
                // not the global setting's to end — that key is still armed and
                // is still the way to stop it.
                guard !self.settings.liveDictation, self.isDictating else { return }
                if let binding = self.pendingEffective?.sourceBinding,
                   HotkeyBindingStore.shared.binding(id: binding.id)?.activation != nil {
                    return
                }
                self.stopDictation()
            }
        }
    }

    /// Live dictation streams partials and needs segment timestamps — only
    /// WhisperKit provides them. With a `llama:*` Qwen3-ASR model active every
    /// trigger falls back to hold-to-talk regardless of what it asked for.
    var canStreamLive: Bool { !LlamaModelOption.isLlamaId(settings.modelId) }

    /// What the Record button and the menu bar do: they have no binding of
    /// their own, so they follow the global live-dictation setting.
    var liveDictationActive: Bool { settings.liveDictation && canStreamLive }

    func toggleRecord() {
        if isDictating { stopDictation(); return }
        if isFinishingDictation { return }   // teardown in flight — ignore
        if liveDictationActive { startDictation(); return }
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// One press of a `toggleLive` binding: stop whatever is running, or start
    /// a live session shaped by that binding.
    func trigger(binding: HotkeyBinding?) {
        if isDictating { stopDictation(); return }
        if isFinishingDictation { return }   // teardown in flight — ignore
        if isRecording { stopRecording(); return }
        startDictation(binding: binding)
    }

    /// Automatic model selection (§38): pick the best installed model for the
    /// current language, hardware and power state.
    ///
    /// Only ever runs *before* audio starts flowing — the model behind a live
    /// recording is never swapped out from under it.
    private func applyAutomaticModelSelection() {
        guard settings.autoSelectModel else { return }
        guard !isRecording, !isDictating, !isFinishingDictation else { return }
        guard !state.isDownloading else { return }
        let installed = ModelRegistry.shared.installedDescriptors
        guard installed.count > 1 else { return }
        guard let best = ModelRecommender.best(from: installed), best.id != settings.modelId else { return }
        settings.modelId = best.id
        NotificationCenter.default.post(name: .modelChanged, object: nil)
        state.showToast("Switched to \(best.displayName) for this dictation.")
    }

    /// Model choice for a dictation. An app profile's explicit model beats
    /// automatic selection — the user named it, the recommender only guessed.
    private func applyModelSelection(_ effective: EffectiveSettings) {
        guard effective.modelFromProfile else {
            applyAutomaticModelSelection()
            return
        }
        guard effective.modelId != settings.modelId, !state.isDownloading else { return }
        settings.modelId = effective.modelId
        NotificationCenter.default.post(name: .modelChanged, object: nil)
        let model = ModelRegistry.shared.descriptor(for: effective.modelId).displayName
        state.showToast("Using \(model) for \(effective.profileName ?? "this app").")
    }

    /// Captures the destination and resolves the profile for a dictation about
    /// to start, then lets the binding that started it override the profile.
    /// Consumes a pending one-off "ignore app profile" request.
    @discardableResult
    private func beginContext(binding: HotkeyBinding? = nil) -> EffectiveSettings {
        let context = AppContext.current()
        let effective = AppProfileStore.shared.resolveForDictation(context: context, binding: binding)
        pendingContext = context
        pendingEffective = effective
        // Both chips, so the notch says which key AND which app shaped this.
        state.sessionLabel = effective.sessionLabel ?? ""
        return effective
    }

    func startRecording(binding: HotkeyBinding? = nil) {
        guard !isRecording, !isDictating, !isFinishingDictation, !awaitingModelForDictation else { return }
        // The Models lab is holding the microphone (recording a test clip or a
        // benchmark sample) — starting a second capture would rip it away.
        guard !state.micReservedByModelLab else {
            state.showToast("Finish the recording in Models first.")
            return
        }
        applyModelSelection(beginContext(binding: binding))
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
        let effective = pendingEffective ?? AppProfileStore.shared.effective(for: pendingContext)
        let context = pendingContext
        state.mode = .transcribing
        let source: TranscriptRecord.Source = effective.sourceBinding == nil ? .button : .hotkey
        Task { await transcribe(samples: samples, source: source, effective: effective, context: context) }
    }

    // MARK: - Live dictation (continuous, types as you speak)

    /// Starts a continuous live-dictation session. The hotkey / Record button
    /// act as a toggle while the "Live dictation" setting is ON.
    func startDictation(binding: HotkeyBinding? = nil) {
        // Re-check the routing on every entry. This method re-enters itself
        // asynchronously after a model load (below), and `.dictationChanged` (or
        // a table edit) can revoke the live session while that load is in
        // flight — without this guard the deferred call would start a live
        // session nothing is left to stop.
        if let binding {
            guard let current = HotkeyBindingStore.shared.binding(id: binding.id),
                  activation(for: current) == .toggleLive else { return }
        } else {
            guard liveDictationActive else { return }
        }
        guard !isDictating, !isRecording, !isFinishingDictation else { return }
        guard !state.micReservedByModelLab else {
            state.showToast("Finish the recording in Models first.")
            return
        }
        // The model must be resident before the live loop starts — otherwise
        // the loop bails on its first tick, leaving `isDictating` stuck true.
        // `ensureLoaded()` drives `state.isLoadingModel`, which surfaces the
        // notch's "Loading model…" progress pill on its own.
        if state.modelStatus != .ready {
            guard !awaitingModelForDictation else { return }
            awaitingModelForDictation = true
            Task { @MainActor in
                let ok = await transcriber.ensureLoaded()
                awaitingModelForDictation = false
                guard ok else {
                    state.mode = .error
                    state.statusMessage = "Model not loaded."
                    return
                }
                // The binding id is carried through the parked start, so the
                // deferred session is still the one the user pressed for.
                startDictation(binding: binding)
            }
            return
        }
        let effective = beginContext(binding: binding)
        live.autoTypeOverride = (effective.sourceProfile == nil && effective.sourceBinding == nil)
            ? nil : effective.autoType
        transcriber.languageOverride = effective.language
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
        isFinishingDictation = true
        state.mode = .transcribing
        Task { await finishDictation() }
    }

    private func finishDictation() async {
        // Cleared only once the mic is actually released — guards the whole
        // async teardown against a concurrent hold-to-talk start.
        defer {
            isFinishingDictation = false
            // Never let a binding's language leak into the next dictation or
            // into a file transcription started from the Upload page.
            transcriber.languageOverride = nil
            live.autoTypeOverride = nil
            state.sessionLabel = ""
        }
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
        let effective = pendingEffective ?? AppProfileStore.shared.effective(for: pendingContext)
        HistoryStore.shared.add(
            raw: result.raw,
            final: result.final,
            corrections: result.corrections,
            source: effective.sourceBinding == nil ? .button : .hotkey,
            profileName: effective.profileName
        )
        // "Newline after text" re-applies at the end of a dictation session,
        // so a full paragraph is followed by a Return press.
        if effective.autoType, effective.insertNewline {
            AutoTyper.type("\n")
        }
        pendingEffective = nil
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
    private func transcribe(samples: [Float], source: TranscriptRecord.Source,
                            effective: EffectiveSettings,
                            context: AppContext) async {
        // A binding may have named a language for this dictation only. Cleared
        // on every exit so it can never bleed into the next one.
        transcriber.languageOverride = effective.language
        defer {
            transcriber.languageOverride = nil
            state.sessionLabel = ""
        }
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
        // Local, private usage metrics for the Models page (§41). Nothing about
        // the audio or the text is recorded — only how long it took.
        let usedModelId = settings.modelId
        let audioSeconds = Double(samples.count) / AudioFileImport.sampleRate
        let startedAt = Date()
        do {
            raw = try await transcriber.transcribe(samples, biasTerms: bias)
        } catch {
            await MainActor.run {
                ModelBenchmarkService.shared.recordUsage(
                    modelId: usedModelId, audioSeconds: audioSeconds,
                    processingSeconds: Date().timeIntervalSince(startedAt), failed: true
                )
                state.mode = .error
                state.statusMessage = "Transcription failed: \(error.localizedDescription)"
                endActivity()
            }
            return
        }
        await MainActor.run {
            ModelBenchmarkService.shared.recordUsage(
                modelId: usedModelId, audioSeconds: audioSeconds,
                processingSeconds: Date().timeIntervalSince(startedAt)
            )
            ModelRegistry.shared.noteUsed(usedModelId)
        }
        // 2) Guaranteed correction pass (longest match first, glued words OK).
        let (final, changes) = DictionaryStore.shared.applyCorrections(raw)

        // 3) Optional local-LLM post-processing. The original transcription is
        // ALWAYS the fallback: any failure keeps the corrected text and the
        // user is told what happened. LLM output can never empty the field.
        var insertText = final
        var recordedMode: ProcessingMode? = nil
        var llmFailed = false
        if effective.pinnedConnectionMissing, !final.isEmpty {
            await MainActor.run {
                state.statusMessage = "Original text inserted — the AI connection \"\(effective.profileName ?? "this profile")\" uses was deleted."
            }
        }
        if effective.llmActive, !final.isEmpty {
            let mode = effective.processingMode
            recordedMode = mode
            await MainActor.run {
                state.mode = .improving
                state.statusMessage = "Improving…"
            }
            let result = await llmRunner.process(final, mode: mode, connectionID: effective.connectionID)
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
            // Insertion always goes wherever focus is NOW — that is
            // AutoTyper's contract. But if the user moved on, the profile that
            // shaped this text no longer matches the destination, so the record
            // says where it actually landed and the toast says so once.
            let destination = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let strayed = effective.sourceProfile != nil
                && destination != nil
                && destination != context.bundleID
            HistoryStore.shared.add(
                raw: raw, final: insertText, corrections: changes,
                source: source, mode: recordedMode,
                profileName: effective.profileName,
                insertedIntoBundleID: strayed ? destination : nil
            )
            if effective.autoType {
                var text = insertText
                if effective.insertNewline, !text.isEmpty { text += "\n" }
                AutoTyper.insert(text, mode: effective.insertionMode)
                if strayed, let destination {
                    state.showToast("Typed into \(AppCatalog.name(for: destination)) — profile was \(effective.profileName ?? "none").")
                }
            }
            pendingEffective = nil
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
        // Single entry point: everything goes through the install queue, which
        // owns ordering, verification and activation-on-finish. Enqueuing the
        // same model twice is a no-op there, so a double-click is harmless.
        ModelDownloadQueue.shared.enqueue(
            ModelRegistry.shared.descriptor(for: modelId)
        )
    }

    /// End any live session after the active model changed by a path that
    /// already handled loading.
    ///
    /// The install queue activates a finished download itself and deliberately
    /// does *not* post `.modelChanged` — that observer would start a second,
    /// racing load of the model it just loaded. The trigger table itself does
    /// not change (activation is resolved per press, at press time), but a
    /// running live session on a model that can no longer stream has to stop.
    func reconcileAfterModelChange() {
        if !canStreamLive, isDictating { stopDictation() }
    }

    var transcriberRef: Transcriber { transcriber }

    /// The one microphone owner in the app. The model test playground records
    /// through this rather than opening a second engine on the same device.
    var recorderRef: AudioRecorder { recorder }

    // MARK: - Local LLM helpers

    var llmRunnerRef: LLMRunner { llmRunner }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
        if isDictating {
            live.cancelNow()
            isDictating = false
        }
        transcriber.llama.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}
