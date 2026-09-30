import AppKit

/// Live dictation, the way live captions work.
///
/// Words appear as soon as they are heard, and the ones still being settled
/// are corrected as the rest of the sentence arrives — in the notch caption,
/// and (with "Correct as you speak" on, the default) in the document itself.
///
/// The pieces:
///  · a `LiveRecognizer` turns the stream into two tiers of text: final words
///    that never change, and a volatile guess at the speech after them.
///    Apple Speech streams natively; Whisper and Parakeet re-decode the whole
///    unfinished phrase on every pass and finalize it at pauses.
///  · this session formats the tiers — dictionary corrections, a capital after
///    a sentence end, spacing where two phrases meet — and hands them to
///  · a `LiveTypist`, which types the difference from what is already on the
///    page: Backspace over the words that changed, then their new version.
///
/// Final text is formatted once, phrase by phrase, and only ever appended to,
/// so a correction can only reach the words not yet final — the last phrase.
///
/// A RUN is the text typed since the session started or since the user last
/// took over the document (typed, clicked, switched apps). Nothing already on
/// the page is touched again after that: the new run types at the cursor,
/// starting with the first word the page does not show. The recognizer is
/// left alone — made to finalize mid-sentence, both kinds cut words in half —
/// so the guess words the page already shows are skipped when they come back.
///
/// `NotchWhisper --live-selftest <file>` replays a recording through all of
/// this in real time — with a virtual page standing in for the focused app,
/// fed the exact keystrokes — and checks the page ends up as the transcript.
@MainActor
final class LiveTranscriber {
    private let state: AppState
    private let settings: Settings
    let recorder: AudioRecorder
    let transcriber: Transcriber

    /// Set by `AppDelegate` at session start when an app profile overrides
    /// "type into the app". nil = follow the global setting.
    var autoTypeOverride: Bool?
    /// Replaces the keystrokes (tests replay audio into a virtual page).
    /// Also turns off the watch for the user's own typing.
    var typingOverride: LiveTypist.Output?
    /// Tests typing for real: keystrokes are sent only while this holds, so a
    /// focus change can never put test text into another app.
    var typingGuard: (@MainActor () -> Bool)?
    /// Stands in for reading the character before the cursor (tests).
    var caretProbeOverride: (@MainActor () -> Character?)?

    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var recognizer: LiveRecognizer?
    private var typist: LiveTypist?
    private var voice = LiveVoiceTracker(sensitivity: .normal)
    private var samplesHeard = 0

    /// The whole session's final text, formatted phrase by phrase — History
    /// and the caption — and how many final words it holds.
    private var sessionFinal = ""
    private var sessionFolded = 0

    /// The current run's final text, formatted exactly as it is typed, and
    /// how many of the recognizer's final words it has taken in.
    private var runFinal = ""
    private var runFolded = 0
    /// What an earlier run's page already shows as its guess, as a skeleton
    /// (`LiveText.skeleton`): skipped from the head of this run's words as
    /// they arrive, final or guessed.
    private var runSkip: [Character] = []
    /// Whether this run types into the app. A run that moved to another app
    /// follows that app's profile ("capture only" apps stay untouched).
    private var runTypes = true
    /// The app the session started in.
    private var sessionApp: pid_t?

    /// The page as the last completed render left it: final words through
    /// this index, the skip still pending, and the guess it typed after them.
    /// A takeover resumes from exactly there.
    private var pageFolded = 0
    private var pageSkip: [Character] = []
    private var pageGuess = ""

    private var renderPending = false
    private var needsNewRun = false
    private var warnedUntrusted = false
    private var warnedSlowModel = false

    init(_ state: AppState, _ settings: Settings, _ recorder: AudioRecorder, _ transcriber: Transcriber) {
        self.state = state
        self.settings = settings
        self.recorder = recorder
        self.transcriber = transcriber
    }

    // MARK: - Lifecycle

    /// Begins the session. The caller has already started the recorder.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        recognizer = nil
        voice = LiveVoiceTracker(sensitivity: settings.vadSensitivity)
        samplesHeard = 0
        sessionFinal = ""
        sessionFolded = 0
        runFinal = ""
        runFolded = 0
        runSkip = []
        pageFolded = 0
        pageSkip = []
        pageGuess = ""
        sessionApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        renderPending = false
        needsNewRun = false
        warnedUntrusted = false
        warnedSlowModel = false
        state.partialText = ""
        state.partialTentative = ""

        let typesIntoApp = autoTypeOverride ?? settings.autoTypeEnabled
        runTypes = typesIntoApp
        let guardTyping = typingGuard
        let output: LiveTypist.Output = typingOverride
            ?? { [weak self] deleting, inserting in
                // "Capture to history only" suppresses the keystrokes, not the
                // transcript: the page model still advances.
                guard self?.runTypes == true, guardTyping?() ?? true else { return "off" }
                return AutoTyper.replace(deleting: deleting, with: inserting)
            }
        self.typist?.end()
        let typist = LiveTypist(style: settings.liveRewrites ? .rewrite : .settledOnly,
                                watchesUser: typingOverride == nil && typesIntoApp,
                                caretProbe: caretProbeOverride ?? LiveTypist.characterBeforeCaret,
                                output: output)
        typist.begin()
        self.typist = typist
        task = Task { await run() }
    }

    /// Ends the session: the last phrase is decoded in full and typed, and the
    /// transcript is returned for History.
    func stop() async -> (raw: String, final: String, corrections: [CorrectionChange]) {
        guard isRunning else { return ("", "", []) }
        let stopAt = Date()
        isRunning = false
        // Let the loop finish the step it is in (a decode is not interrupted
        // mid-typing), so nothing below races it.
        task?.cancel()
        await task?.value
        task = nil

        // The mic is released now; the rest works on what it captured.
        let tail = recorder.stop()
        if let recognizer {
            if !tail.isEmpty {
                voice.append(tail)
                recognizer.append(tail)
            }
            // The shortcut that stopped the session is not the user taking
            // over the page.
            typist?.forgiveStopShortcut(at: stopAt)
            await recognizer.finish()
            // Type the rest. Typing is often held back for a moment here — the
            // default stop key is ⌥, still down when a fast engine finishes;
            // keystrokes may still be landing — so keep at it briefly rather
            // than leave the last phrase off the page.
            let deadline = Date().addingTimeInterval(3)
            while true {
                if needsNewRun || (typist?.isInterrupted ?? false) { startNewRun() }
                if render() || Date() > deadline { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        typist?.end()
        typist = nil

        state.partialTentative = ""
        let words = recognizer?.finalWords ?? []
        recognizer = nil
        let raw = LiveText.text(of: words)
        let (_, changes) = DictionaryStore.shared.applyCorrections(raw)
        return (raw: raw, final: sessionFinal, corrections: changes)
    }

    /// Synchronous teardown for app terminate: no final pass.
    func cancelNow() {
        isRunning = false
        task?.cancel()
        task = nil
        recognizer?.cancel()
        recognizer = nil
        typist?.end()
        typist = nil
        _ = recorder.stop()
    }

    /// Tests: behave as if the user had just clicked into the page.
    func simulateUserTookOver() {
        needsNewRun = true
    }

    /// Tests: hold typing back until `date`, as a held modifier key does.
    func holdTypingForTest(until date: Date) {
        typist?.holdTypingUntil = date
    }

    // MARK: - Loop

    private func run() async {
        guard await transcriber.ensureLoaded() else {
            state.mode = .error
            state.statusMessage = "Model not loaded."
            return
        }
        let recognizer: LiveRecognizer
        do {
            recognizer = try await transcriber.makeLiveRecognizer()
            recognizer.onUpdate = { [weak self] in self?.scheduleRender() }
            try await recognizer.start()
        } catch {
            fputs("NotchWhisper[live]: could not start: \(error)\n", stderr)
            // Stopped before it got going: not an error worth showing.
            guard isRunning, !Task.isCancelled else { return }
            state.mode = .error
            state.statusMessage = error.localizedDescription
            return
        }
        // Set even when stop() already ran: it finishes this recognizer with
        // everything the mic captured while the model was loading.
        self.recognizer = recognizer

        while isRunning, !Task.isCancelled {
            let started = Date()
            pump()
            if autoStopDue() {
                AppDelegate.shared?.stopDictation()
                return
            }
            // Acted on after a moment, so the shortcut that stops the session
            // can arrive first and be told apart (see `stop()`); typing is
            // held back meanwhile.
            if needsNewRun || (typist?.interruptedFor ?? 0) >= 0.3 { startNewRun() }
            await recognizer.process()
            guard isRunning, !Task.isCancelled else { break }
            render()
            noteDecodeCost(recognizer.meanDecodeSeconds)
            let rest = max(0.02, recognizer.tickSeconds - Date().timeIntervalSince(started))
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
        }
    }

    /// Moves what the mic captured since the last pass into the recognizer.
    private func pump() {
        let chunk = recorder.drainSamples()
        guard !chunk.isEmpty else { return }
        samplesHeard += chunk.count
        voice.append(chunk)
        recognizer?.append(chunk)
    }

    /// Spec 04: a session may end itself after a configured silence. Off by
    /// default — a session ending while the user thinks is worse than one
    /// that runs on.
    private func autoStopDue() -> Bool {
        let limit = settings.liveAutoStopSeconds
        guard limit > 0 else { return false }
        let quietFrom = voice.lastSpeechEnd ?? 0
        return Double(samplesHeard - quietFrom) / Double(LiveVoiceTracker.sampleRate) >= Double(limit)
    }

    /// The user took over the document. Everything on the page stays as it
    /// is; the new run starts right after it — with the first final word the
    /// page did not show, less the guess words it did.
    private func startNewRun() {
        needsNewRun = false
        guard let typist else { return }
        runFinal = ""
        runFolded = pageFolded
        runSkip = pageSkip + LiveText.skeleton(pageGuess)
        pageSkip = runSkip
        pageGuess = ""
        typist.startNewRun()
        // In another app now: that app's profile decides whether it is typed
        // into (a password manager, a "capture only" app).
        if typingOverride == nil, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           front != sessionApp {
            runTypes = AppProfileStore.shared.effective(for: AppContext.current()).autoType
        }
        foldRunFinal()
        fputs("NotchWhisper[live]: user took over the page — new run after final word \(pageFolded)"
              + (runSkip.isEmpty ? "" : ", skipping \(runSkip.count) letters already typed") + "\n", stderr)
    }

    // MARK: - Rendering

    /// Recognizers publish in bursts (Apple Speech sends every partial word);
    /// one render per burst is enough.
    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self else { return }
            self.renderPending = false
            self.render()
        }
    }

    /// Brings the page and the caption up to date. Returns true when the page
    /// now shows everything it should.
    @discardableResult
    private func render() -> Bool {
        guard let recognizer, let typist else { return false }
        foldSessionFinal()
        foldRunFinal()

        // The page: this run's final text, then the settled part of the guess,
        // less whatever of it an earlier run's page already shows.
        var guessText = format(LiveText.text(of: recognizer.settledWords), after: runFinal)
        if !runSkip.isEmpty {
            let dropped = LiveText.dropCovered(runSkip, from: guessText)
            guessText = dropped.left.isEmpty ? dropped.rest.trimmingCharacters(in: .whitespaces) : ""
        }
        var current = false
        if needsNewRun || typist.isInterrupted {
            // The loop starts the new run; nothing is typed until then.
        } else {
            let path = typist.render(finalText: runFinal, full: LiveText.join(runFinal, guessText))
            if path == "untrusted", !warnedUntrusted {
                warnedUntrusted = true
                state.showToast("Enable Accessibility for NotchWhisper to type text (System Settings → Privacy & Security).")
            }
            if typist.isCurrent {
                current = true
                pageFolded = runFolded
                pageSkip = runSkip
                pageGuess = typist.guessOnPage
            }
        }

        // The caption: the whole session, and the whole guess.
        let guessed = format(LiveText.text(of: recognizer.volatileWords), after: sessionFinal)
        state.partialText = String(sessionFinal.suffix(400))
        state.partialTentative = String(LiveText.join(sessionFinal, guessed).dropFirst(sessionFinal.count))
        return current
    }

    /// Takes the final words published since the last render into the
    /// session's text: each batch is one phrase, corrected and cased once.
    private func foldSessionFinal() {
        guard let recognizer, sessionFolded < recognizer.finalWords.count else { return }
        let fresh = recognizer.finalWords[sessionFolded...]
        sessionFolded = recognizer.finalWords.count
        sessionFinal = LiveText.join(sessionFinal, format(LiveText.text(of: fresh), after: sessionFinal))
    }

    /// The same for the current run's text, less the words the page already
    /// shows. Appended, never reformatted: it may already be typed.
    private func foldRunFinal() {
        guard let recognizer, runFolded < recognizer.finalWords.count else { return }
        let fresh = recognizer.finalWords[runFolded...]
        runFolded = recognizer.finalWords.count
        var text = format(LiveText.text(of: fresh), after: runFinal)
        if !runSkip.isEmpty {
            let dropped = LiveText.dropCovered(runSkip, from: text)
            runSkip = dropped.left
            text = dropped.rest.trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return }
        runFinal = LiveText.join(runFinal, text)
    }

    /// Dictionary corrections and a capital after a sentence end.
    private func format(_ text: String, after previous: String) -> String {
        guard !text.isEmpty else { return "" }
        let corrected = DictionaryStore.shared.applyCorrections(text).result
        return LiveText.capitalizingAfterSentenceEnd(corrected, typed: previous)
    }

    // MARK: - Slow models

    /// A re-decoding engine can only update as fast as one pass, and a pass
    /// costs about the same however much speech it carries — most of it is the
    /// encoder. A model whose pass takes most of a second makes the caption
    /// trail the speaker, so say so once, with the number, rather than letting
    /// it read as the app being broken. (Measured on an M4: Whisper large-v3
    /// turbo ~1.1 s a pass, its 632 MB build ~0.5 s, base ~0.1 s; Parakeet
    /// ~0.05 s.)
    private func noteDecodeCost(_ mean: Double?) {
        guard !warnedSlowModel, let mean, mean > 0.9 else { return }
        warnedSlowModel = true
        let name = ModelRegistry.shared.descriptor(for: settings.modelId).displayName
        state.showToast("\(name) takes about \(String(format: "%.1f", mean)) s per live pass, "
                        + "so live text will trail your voice. A lighter model keeps up — see Models.")
    }
}
