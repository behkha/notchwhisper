import Foundation
import WhisperKit

/// Live, continuous dictation ("type as you speak").
///
/// While active the shared `AudioRecorder` keeps capturing (so the notch
/// waveform and visualizer keep working) and this class runs a transcription
/// loop on a ~0.35 s cadence. Every pass:
///
///  1. Transcribes a SHORT bounded window — the last `overlapSeconds` of
///     already-TYPED audio plus everything new (the window never grows:
///     committed audio is trimmed away, so each pass decodes only a few
///     seconds and latency stays flat no matter how long the session runs).
///  2. Treats a segment as stable/confirmed when it ends at least
///     `confirmLagSeconds` before the live edge of the window (audio that
///     Whisper has already seen well beyond — it can no longer change).
///     When the user PAUSES (no new audio for `pauseFlushDelay`), the lag is
///     relaxed to `pauseFlushConfirmLag` so the pending sentence types
///     promptly instead of waiting for more speech (or for Stop).
///  3. Types every stable segment that carries untyped audio, addressed by
///     SAMPLE POSITION rather than text matching:
///       · segment ends ≤ the typed boundary  → pure re-read, skipped;
///       · segment begins in untyped audio    → typed in full;
///       · segment crosses the boundary       → word-diffed, only the
///         net-new tail typed (`newChunk`).
///     The old design diffed text only and committed one pointer per pass:
///     when Whisper re-segmented a boundary the whole region could be typed
///     twice (duplicates) or — after the trim — never re-decoded again
///     (dropped sentences). Sample addressing removes both failure modes,
///     and audio is only trimmed after its text is typed, so no spoken word
///     can fall out of the buffer un-transcribed.
///  4. Publishes the live transcript to `AppState.partialText` for the notch
///     ribbon, and skips the decode entirely while the mic reads silence AND
///     nothing is pending (saves CPU and prevents Whisper hallucinating on
///     quiet audio).
///  5. WATCHDOG: if ≥2 s of audio is pending but nothing has been committed
///     for >1.5 s (confirmation can stall when Whisper returns a single
///     segment spanning to the live window edge, or its timestamps drift),
///     the pending tail is force-decoded and typed, so output keeps flowing
///     continuously instead of dying after the first sentence(s).
///
/// On `stop()` the untyped tail is transcribed one final time (it can no
/// longer change) and typed in full, then the composed transcript is returned
/// for the History store.
@MainActor
final class LiveTranscriber {
    private let state: AppState
    private let settings: Settings
    let recorder: AudioRecorder
    let transcriber: Transcriber

    static let sampleRate = Double(WhisperKit.sampleRate)   // 16000
    private let tickNanoseconds: UInt64 = 350_000_000       // 0.35 s re-transcribe cadence
    private let minNewAudioSeconds: Float = 0.25
    /// How much already-typed audio to keep as left context so the first
    /// segment of every pass isn't cut mid-word.
    private let overlapSeconds: Float = 0.9
    /// A segment is confirmed when its end sits at least this far before the
    /// live (latest) edge of the transcribed window.
    private let confirmLagSeconds: Float = 0.5
    /// While the user is paused (no new audio for this long) the confirm lag
    /// relaxes to `pauseFlushConfirmLag`: the tail can no longer change, so
    /// it is typed right away instead of hanging until speech resumes.
    private let pauseFlushDelay: TimeInterval = 1.2
    private let pauseFlushConfirmLag: Float = 0.12
    /// Skip the decode while the mic level is under this (silence) — the
    /// level ring is normalized 0.06…1.0 by the recorder — but only when
    /// there is no pending tail worth flushing.
    private let silenceLevel: Float = 0.075
    /// Timestamp slop for segment boundaries (0.1 s in samples).
    private let boundaryEpsSamples: Int = 1_600
    /// A segment starting this deep inside typed audio is a re-decode of the
    /// window's left context; only act on it when it also carries significant
    /// new audio (below).
    private let deepCrossSeconds: Float = 0.5
    private let deepCrossForceSeconds: Float = 1.0

    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    /// Set when a typing attempt hit a missing Accessibility grant, so the
    /// warning is shown once per session instead of on every delta.
    private var warnedUntrusted = false

    /// Buffer-relative sample index: all audio BEFORE this point has been
    /// transcribed AND typed at the cursor. Audio after it is pending.
    private var typedUpto = 0
    /// Buffer-relative live edge of the last decode pass (for the "enough new
    /// audio" gate). Always ≥ `typedUpto`.
    private var decodedUpto = 0
    /// Recorder-buffer bookkeeping for the pause detector.
    private var lastBufferSize = 0
    private var lastAudioGrowth = Date()
    /// Last time text was actually committed to the cursor (`typedUpto`
    /// advanced or a tail was typed). Drives the anti-stall watchdog: the
    /// confirm path can stall forever when Whisper keeps returning segments
    /// that reach the live window edge (typical mid-sentence), so after a
    /// commit drought with a meaningful pending tail we force-flush.
    private var lastCommitAt = Date()
    /// The literal text already typed at the cursor during this session.
    private var typedText = ""
    /// Raw (pre-correction) running text of the whole session, for History.
    private var rawAccumulated = ""

    init(_ state: AppState, _ settings: Settings, _ recorder: AudioRecorder, _ transcriber: Transcriber) {
        self.state = state
        self.settings = settings
        self.recorder = recorder
        self.transcriber = transcriber
    }

    // MARK: - Lifecycle

    /// Begins the live session. The caller must already have started the
    /// recorder; the loop reads its history on each tick.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        typedUpto = 0
        decodedUpto = 0
        lastBufferSize = 0
        lastAudioGrowth = Date()
        lastCommitAt = Date()
        typedText = ""
        rawAccumulated = ""
        warnedUntrusted = false
        state.partialText = ""
        task = Task { await runLoop() }
    }

    /// Stops the loop, flushes the untyped tail into the focused field,
    /// and returns the composed transcript for History.
    func stop() async -> (raw: String, final: String, corrections: [CorrectionChange]) {
        guard isRunning else { return ("", "", []) }
        isRunning = false
        task?.cancel()
        task = nil

        // Final flush: whatever is still untyped is final now — type it
        // wholesale (one clean pass, starting exactly at the typed boundary).
        let samples = recorder.accumulatedSamples
        let tailSamples = samples.count > typedUpto
            ? Array(samples.suffix(from: typedUpto))
            : []
        if !tailSamples.isEmpty {
            await flush(tailSamples)
        }
        _ = recorder.stop()

        let raw = rawAccumulated
        let final = typedText
        let (_, changes) = DictionaryStore.shared.applyCorrections(raw)
        return (raw: raw, final: final, corrections: changes)
    }

    // MARK: - Loop

    private func runLoop() async {
        guard await transcriber.ensureLoaded() else {
            state.mode = .error
            state.statusMessage = "Model not loaded."
            isRunning = false
            return
        }
        while isRunning {
            try? await Task.sleep(nanoseconds: tickNanoseconds)
            guard isRunning else { break }
            await tick()
        }
    }

    private func tick() async {
        let samples = recorder.accumulatedSamples
        let now = Date()
        if samples.count > lastBufferSize { lastAudioGrowth = now }
        lastBufferSize = samples.count

        let pendingSamples = samples.count - typedUpto
        guard pendingSamples > 0 else { return }          // everything typed: nothing to do
        let pendingSeconds = Float(pendingSamples) / Float(Self.sampleRate)
        let paused = now.timeIntervalSince(lastAudioGrowth) >= pauseFlushDelay
        let enoughNew = Float(samples.count - decodedUpto) / Float(Self.sampleRate) >= minNewAudioSeconds

        // Silence gate: don't spend a decode while nothing is being said AND
        // there is no pending tail worth flushing. (The recorder normalizes
        // levels to 0.06…1.0; ~0.075 is a quiet room.)
        if (state.levels.max() ?? 0) < silenceLevel,
           !paused, pendingSeconds < 0.5 { return }

        // ANTI-STALL WATCHDOG: text commits only when a segment ends ≥0.5 s
        // before the live window edge. When Whisper returns a single segment
        // spanning to the live edge (typical for continuous speech) or its
        // timestamps drift, NOTHING commits: typedUpto freezes, the decode
        // window grows without bound, latency explodes and output dies after
        // the first sentence(s). If a meaningful tail has been pending while
        // no commit happened recently, force-type it now.
        if pendingSeconds >= 2.0, now.timeIntervalSince(lastCommitAt) >= 1.5 {
            fputs("NotchWhisper[live]: watchdog — pending \(String(format: "%.1f", pendingSeconds))s with no commit for \(String(format: "%.1f", now.timeIntervalSince(lastCommitAt)))s; forcing tail flush\n", stderr)
            await forceFlush(samples)
            return
        }

        // Decode triggers: normal cadence (enough new audio), or the
        // pause-flush (the user stopped speaking but a tail is still untyped).
        guard enoughNew || (paused && pendingSeconds >= 0.3) else { return }

        // Bounded sliding window: last `overlapSeconds` of typed audio + all new.
        let start = max(0, typedUpto - Int(Float(Self.sampleRate) * overlapSeconds))
        guard start < samples.count else { return }
        let window = Array(samples.suffix(from: start))
        guard !window.isEmpty else { return }

        let segments: [TranscriptionSegment]
        do {
            segments = try await transcriber.liveTranscribe(
                window,
                biasTerms: DictionaryStore.shared.biasingTerms()
            )
        } catch {
            // A transient failure mid-dictation: keep listening, retry next
            // tick. (Logged — a silently swallowing loop is undebuggable.)
            fputs("NotchWhisper[live]: decode failed (will retry): \(error)\n", stderr)
            return
        }
        decodedUpto = samples.count
        fputs("NotchWhisper[live]: pass buf=\(String(format: "%.1f", Float(samples.count) / Float(Self.sampleRate)))s pending=\(String(format: "%.1f", pendingSeconds))s segs=\(segments.count) typedUpto=\(typedUpto)\n", stderr)
        guard !segments.isEmpty else { return }

        // Live partial for the notch: everything recognized so far this pass.
        let partial = Self.canonicalize(segments.map(\.text).joined(separator: " "))
        if !partial.isEmpty {
            state.partialText = Self.canonicalize("\(typedText) \(partial)".trimmingCharacters(in: .whitespaces))
        }

        // Confirm segments that Whisper has seen well past their end — they
        // can no longer change. While the user is PAUSED the tail cannot be
        // revised by future audio, so the lag relaxes and the pending
        // sentence types immediately.
        let windowSeconds = Float(window.count) / Float(Self.sampleRate)
        let stableEnd = (paused && !enoughNew)
            ? windowSeconds - pauseFlushConfirmLag
            : windowSeconds - confirmLagSeconds
        let stable = segments.filter { $0.end <= stableEnd }
        if stable.isEmpty {
            fputs("NotchWhisper[live]: \(segments.count) segment(s) decoded, none stable yet (stableEnd=\(String(format: "%.2f", stableEnd))s)\n", stderr)
            return
        }

        // Type every stable segment that carries untyped audio, in order.
        let typedBefore = typedUpto
        for seg in stable {
            let text = Self.canonicalize(seg.text)
            guard !text.isEmpty else { continue }
            let segStart = start + Int(seg.start * Float(Self.sampleRate))
            let segEnd = start + Int(seg.end * Float(Self.sampleRate))

            if segEnd <= typedUpto + boundaryEpsSamples {
                continue    // pure re-read of already-typed audio
            }
            if segStart >= typedUpto - boundaryEpsSamples {
                // Entirely new audio → type in full. Sample addresses, not
                // text matching, decide this: a repeated phrase must type.
                appendAndType(text)
            } else if segStart >= typedUpto - Int(deepCrossSeconds * Float(Self.sampleRate)) {
                // Crosses the typed boundary (the normal boundary-spanning
                // case): strip words already typed, type the net-new tail.
                typeTail(text)
            } else if segEnd - typedUpto > Int(deepCrossForceSeconds * Float(Self.sampleRate)) {
                // Deep re-read that still carries significant new audio:
                // diff and type rather than risk losing the tail.
                typeTail(text)
            } else {
                // Deep re-read with little new audio: a decode artifact of
                // the window's left context. Skip it; the new tail will be
                // confirmed cleanly in a later pass.
                continue
            }
            typedUpto = max(typedUpto, segEnd)
        }
        if typedUpto != typedBefore { lastCommitAt = now }

        // Bound memory: drop the fully-typed prefix, keeping the overlap
        // region as left context for the next pass. Audio is only removed
        // AFTER its text is typed — nothing pending can fall out.
        let trim = max(0, typedUpto - Int(Float(Self.sampleRate) * overlapSeconds))
        if trim > 0 {
            // Adjust bookkeeping by the number ACTUALLY dropped — trimming
            // fewer than requested must not desync the sample indices.
            let dropped = recorder.trimSamples(trim)
            if dropped != trim {
                fputs("NotchWhisper[live]: trim requested \(trim), actually dropped \(dropped)\n", stderr)
            }
            typedUpto -= dropped
            decodedUpto -= dropped
            lastBufferSize -= dropped
        }
    }

    /// Synchronous teardown for app terminate: cancels the loop and releases
    /// the mic without the async final flush (app is going away anyway).
    func cancelNow() {
        isRunning = false
        task?.cancel()
        task = nil
        _ = recorder.stop()
    }

    /// One clean pass over the whole untyped tail (after the loop has
    /// stopped) — it can no longer change, so it is typed in full.
    private func flush(_ samples: [Float]) async {
        let segments: [TranscriptionSegment]
        do {
            segments = try await transcriber.liveTranscribe(
                samples,
                biasTerms: DictionaryStore.shared.biasingTerms()
            )
        } catch {
            return
        }
        let text = Self.canonicalize(segments.map(\.text).joined(separator: " "))
        guard !text.isEmpty else { return }
        // The tail begins at the typed boundary, so its text is new; still
        // route through the word-diff to be safe against boundary re-words.
        typeTail(text)
        typedUpto = recorder.accumulatedSamples.count
        state.partialText = typedText
    }

    /// Watchdog hard-flush: the confirm path has stalled while a meaningful
    /// tail is pending. Re-decode the pending tail WITH the usual overlap
    /// (so the fragment doesn't start mid-word), word-diff against what was
    /// already typed, and if the diff produced text, commit the WHOLE pending
    /// region (its text is now typed — nothing can be lost by advancing).
    /// If the decode produced nothing new, the audio stays pending and the
    /// watchdog re-fires on the next tick rather than dropping speech.
    private func forceFlush(_ samples: [Float]) async {
        let start = max(0, typedUpto - Int(Float(Self.sampleRate) * overlapSeconds))
        guard start < samples.count else { return }
        let window = Array(samples.suffix(from: start))
        let segments: [TranscriptionSegment]
        do {
            segments = try await transcriber.liveTranscribe(
                window,
                biasTerms: DictionaryStore.shared.biasingTerms()
            )
        } catch {
            fputs("NotchWhisper[live]: watchdog flush decode failed: \(error)\n", stderr)
            return
        }
        decodedUpto = max(decodedUpto, samples.count)
        let text = Self.canonicalize(segments.map(\.text).joined(separator: " "))
        guard !text.isEmpty else {
            fputs("NotchWhisper[live]: watchdog flush decoded no text — keeping audio pending\n", stderr)
            return
        }
        let typed = typeTail(text)
        if typed.isEmpty {
            fputs("NotchWhisper[live]: watchdog flush diffed to a pure re-read — keeping audio pending\n", stderr)
        } else {
            typedUpto = samples.count
            lastCommitAt = Date()
            state.partialText = typedText
            fputs("NotchWhisper[live]: watchdog committed: \"\\(typed)\"\n", stderr)
        }
    }

    // MARK: - Delta typing

    /// Types fully-new text (a segment addressed entirely in untyped audio)
    /// WITHOUT the word-diff: a repeated phrase is genuinely new speech and
    /// must be typed, which text-overlap matching would wrongly drop.
    private func appendAndType(_ text: String) {
        rawAccumulated = Self.canonicalize("\(rawAccumulated) \(text)".trimmingCharacters(in: .whitespaces))

        let (corrected, _) = DictionaryStore.shared.applyCorrections(text)
        let tail = Self.canonicalize(corrected)
        guard !tail.isEmpty else { return }
        guard settings.autoTypeEnabled else { return }

        let path = AutoTyper.type(tail)
        if path == "untrusted", !warnedUntrusted {
            warnedUntrusted = true
            state.showToast("Enable Accessibility for NotchWhisper to type text (System Settings → Privacy & Security).")
        }
        typedText = Self.canonicalize("\(typedText) \(tail)".trimmingCharacters(in: .whitespaces))
    }

    /// Corrects the incoming raw text, drops any words already typed (a
    /// boundary-spanning segment re-reads the typed edge), and types exactly
    /// the net-new tail at the cursor. Returns the tail that was typed.
    ///
    /// The overlap diff runs against the session's RAW committed text
    /// (`rawAccumulated`), NOT the corrected `typedText`: the re-read words
    /// come from Whisper decoding raw audio, so matching raw against raw is
    /// stable — dictionary corrections and case changes applied to `typedText`
    /// would break the match and cause duplicated (or lost) tails.
    @discardableResult
    private func typeTail(_ rawNewText: String) -> String {
        // A boundary-spanning chunk may begin with words already at the end
        // of what we typed. Strip that overlap so we never re-type — but
        // never DISCARD the chunk when no overlap matches.
        guard let chunk = Self.newChunk(typed: rawAccumulated, fresh: rawNewText),
              !chunk.isEmpty else { return "" }

        // Keep the session's RAW text for history, independent of corrections.
        rawAccumulated = Self.canonicalize("\(rawAccumulated) \(chunk)".trimmingCharacters(in: .whitespaces))

        // Dictionary correction pass. Applied to the net-new tail only — a
        // correction phrase rarely spans two deltas, and applying it to the
        // whole running text would re-type already-typed words when a phrase
        // happens to complete across a delta.
        let (corrected, _) = DictionaryStore.shared.applyCorrections(chunk)
        let tail = Self.canonicalize(corrected)
        guard !tail.isEmpty else { return "" }
        guard settings.autoTypeEnabled else { return "" }

        let path = AutoTyper.type(tail)
        if path == "untrusted", !warnedUntrusted {
            warnedUntrusted = true
            state.showToast("Enable Accessibility for NotchWhisper to type text (System Settings → Privacy & Security).")
        }
        typedText = Self.canonicalize("\(typedText) \(tail)".trimmingCharacters(in: .whitespaces))
        return tail
    }

    // MARK: - Text helpers

    /// Collapses all whitespace runs to single spaces and trims the edges —
    /// Whisper sometimes attaches stray spaces to segment boundaries.
    static func canonicalize(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Returns the net-new portion of `fresh` (the newly-confirmed text) after
    /// removing any leading words that were already typed — i.e. the overlap
    /// where a segment re-reads a tail of confirmed audio.
    ///
    /// Returns nil ONLY when `fresh` is entirely made of already-typed words
    /// (a pure re-read of committed audio). When no overlap matches at all
    /// (Whisper reworded the boundary region) the whole chunk is returned —
    /// typing a rare duplicate word is always better than losing text.
    ///
    /// Matching is CASE-INSENSITIVE: the typed text may differ from Whisper's
    /// raw output only by casing (dictionary corrections, sentence casing),
    /// and a case-only mismatch must not defeat the overlap detection.
    static func newChunk(typed: String, fresh: String) -> String? {
        let freshWords = fresh.split(separator: " ")
        guard !freshWords.isEmpty else { return nil }
        guard !typed.isEmpty else { return fresh }

        let typedWords = typed.split(separator: " ")
        let fold = { (words: [Substring]) in words.map { $0.lowercased() } }
        let freshFolded = fold(Array(freshWords))
        let typedFolded = fold(Array(typedWords))

        // Pure re-read: the entire fresh chunk is the tail of the typed text.
        if freshWords.count <= typedWords.count,
           freshFolded == Array(typedFolded.suffix(freshWords.count)) {
            return nil
        }

        // Longest leading overlap of `fresh` with the typed suffix wins.
        let maxOverlap = min(typedWords.count, freshWords.count - 1)
        if maxOverlap > 0 {
            for o in stride(from: maxOverlap, through: 1, by: -1)
            where Array(freshFolded.prefix(o)) == Array(typedFolded.suffix(o)) {
                let tail = freshWords.dropFirst(o)
                return tail.isEmpty ? nil : tail.joined(separator: " ")
            }
        }
        // No recognizable overlap → type the whole chunk (never drop text).
        return fresh
    }
}
