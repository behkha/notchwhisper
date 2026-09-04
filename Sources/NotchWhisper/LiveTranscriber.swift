import Foundation
import WhisperKit

/// Live, continuous dictation ("type as you speak").
///
/// While active the shared `AudioRecorder` keeps capturing (so the notch
/// waveform and visualizer keep working) and this class runs ONE transcription
/// pass per tick, on a ~0.30 s cadence that subtracts the previous decode's
/// cost so it does not drift. Every pass:
///
///  1. Checks the audio, not the UI meter, for speech. A pending region with
///     no speech in it is retired without a decode: Whisper hallucinates
///     confidently on silence and the live path types whatever it returns.
///  2. Transcribes a SHORT bounded window — the last `overlapSeconds` of
///     already-TYPED audio plus everything new, never shorter than
///     `minWindowSeconds` (Whisper invents paragraphs when fed a second and a
///     half) and never longer than `maxWindowSeconds`, so each pass decodes a
///     few seconds and latency stays flat however long the session runs.
///  3. Decides what has SETTLED. Every segment except the last is closed —
///     Whisper ends one early only when it decided the phrase finished there —
///     and the last settles once it ends `confirmLagSeconds` before the live
///     edge (relaxed to `pauseFlushConfirmLag` while the user is paused, when
///     no future audio can revise it).
///  4. Types every settled segment that carries untyped audio, addressed by
///     SAMPLE POSITION rather than text matching:
///       · segment ends ≤ the typed boundary  → pure re-read, skipped;
///       · segment begins in untyped audio    → typed in full;
///       · segment crosses the boundary       → word-diffed, only the
///         net-new tail typed (`newChunk`).
///     Diffing text alone would type a region twice when Whisper re-segmented
///     a boundary, or drop it after the trim; sample addressing removes both,
///     and audio is only trimmed after its text is typed, so no spoken word
///     can fall out of the buffer un-transcribed.
///  5. Publishes the live transcript to `AppState.partialText` for the notch
///     ribbon.
///
/// ANTI-STALL. Settling can fail indefinitely — Whisper returns one segment
/// spanning to the live edge, or its timestamps drift — so once the pending
/// tail passes `forcePendingSeconds` with no commit for `forceDroughtSeconds`,
/// the pass commits what it decoded regardless. This is a MODE of the pass
/// above, never a decode that pre-empts it: the previous design force-flushed
/// *before* the normal path, and because only a commit could bring pending back
/// down, one stall meant every remaining tick was spent in the fallback. That
/// deadlock is why dictation used to arrive in late bursts instead of flowing.
///
/// On `stop()` the untyped tail is transcribed one final time (it can no
/// longer change) and typed in full, then the composed transcript is returned
/// for the History store.
///
/// A note on what this can and cannot fix: a pass costs roughly the same
/// whether it carries half a second of speech or four, because most of it is
/// the encoder, whose size is fixed by the model. Measured on an M4, a
/// two-second window costs ~1.1 s on Whisper large-v3 turbo and ~0.08 s on
/// base. No scheduling here rescues a model whose pass costs more than the
/// audio it captures — `noteDecodeCost` says so out loud instead.
/// `NotchWhisper --live-selftest <file>` replays a recording through this loop
/// with no microphone, and `--live-bench <file>` times the decode alone.
@MainActor
final class LiveTranscriber {
    private let state: AppState
    private let settings: Settings
    let recorder: AudioRecorder
    let transcriber: Transcriber

    /// Set by `AppDelegate` at session start when an app profile overrides
    /// "type into the app". nil = follow the global setting.
    var autoTypeOverride: Bool?

    static let sampleRate = Double(WhisperKit.sampleRate)   // 16000
    /// Target period between decode passes. The loop subtracts the previous
    /// decode's cost from its sleep, so passes stay this far apart instead of
    /// drifting out to `tickSeconds + decodeSeconds`.
    private let tickSeconds: TimeInterval = 0.30
    /// Never spin: always yield at least this long between passes.
    private let minSleepSeconds: TimeInterval = 0.05
    private let minNewAudioSeconds: Float = 0.25
    /// How much already-typed audio to keep as left context so the first
    /// segment of every pass isn't cut mid-word.
    private let overlapSeconds: Float = 0.9
    /// Whisper is trained on 30 s windows and hallucinates freely on very short
    /// ones — fed 1.5 s it will confidently invent a paragraph, which the live
    /// path then types. Waiting for this much audio before the first decode
    /// costs a fraction of a second at the start of a session and removes the
    /// worst output the loop can produce.
    private let minWindowSeconds: Float = 2.0
    /// Hard cap on the decode window. Without this, if confirmation stalls the
    /// window grows from `typedUpto` back to ~0, Whisper then returns one long
    /// segment that reaches the live edge (never "stable"), and NOTHING commits
    /// — the classic "types the first sentence then dies". A bounded window
    /// keeps segments short enough that the stability check actually fires; the
    /// watchdog covers the rare case where even a short window won't confirm.
    private let maxWindowSeconds: Float = 8.0
    /// A segment is confirmed when its end sits at least this far before the
    /// live (latest) edge of the transcribed window.
    private let confirmLagSeconds: Float = 0.4
    /// While the user is paused (no new audio for this long) the confirm lag
    /// relaxes to `pauseFlushConfirmLag`: the tail can no longer change, so
    /// it is typed right away instead of hanging until speech resumes.
    private let pauseFlushDelay: TimeInterval = 1.2
    private let pauseFlushConfirmLag: Float = 0.12
    /// Skip the decode while the audio is under this (silence) — levels are
    /// normalized 0.06…1.0, the same scale the recorder publishes — but only
    /// when there is no pending tail worth flushing.
    private let silenceLevel: Float = 0.075
    /// How much of the live edge the voice probe looks at. Long enough to ride
    /// over the gaps inside normal speech, short enough that a real pause
    /// registers within one `pauseFlushDelay`.
    private let voiceProbeSeconds: Float = 0.35
    /// Anti-stall: a pending tail at least this long, with no commit for at
    /// least `forceDroughtSeconds`, is committed from the next decode whether
    /// or not its segments look settled.
    private let forcePendingSeconds: Float = 1.2
    private let forceDroughtSeconds: TimeInterval = 0.8
    /// Longest repeated phrase `deloop` will collapse. A Whisper decoder loop
    /// usually latches onto a whole short sentence, not a single word.
    static let maxLoopPhraseWords = 12
    /// Mean decode cost above which live dictation visibly runs behind. Set
    /// just over twice the tick, so a model that keeps the loop near its
    /// intended cadence never trips it.
    private let slowDecodeSeconds: TimeInterval = 0.7
    /// How far a segment may move between passes and still count as the same
    /// one. Whisper's timestamps wobble by a frame or two as a window grows.
    private let agreementSlopSeconds: Float = 0.3
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
    /// Last tick at which the mic level was above the silence floor. The mic
    /// tap appends audio CONTINUOUSLY (silence included), so "the buffer is
    /// still growing" is not a usable "still speaking" signal — the pause
    /// detector keys off the level instead.
    private var lastVoiceAt = Date()
    /// Set once per pause after the pre-pause tail has been salvaged, so the
    /// next paused tick collapses the retained silence instead of re-flushing.
    private var pauseSalvaged = false
    /// Last time text was actually committed to the cursor (`typedUpto`
    /// advanced or a tail was typed). Drives the anti-stall watchdog: the
    /// confirm path can stall forever when Whisper keeps returning segments
    /// that reach the live window edge (typical mid-sentence), so after a
    /// commit drought with a meaningful pending tail we force-flush.
    private var lastCommitAt = Date()
    /// Wall-clock cost of the most recent decode. The tick sleep subtracts it
    /// so the loop keeps a steady cadence instead of drifting to
    /// `tickSeconds + decodeSeconds` per pass.
    private var lastDecodeSeconds: TimeInterval = 0
    /// Total samples trimmed off the FRONT of the recorder buffer this session.
    /// `typedUpto` is buffer-relative and shifts on every trim; adding this
    /// back gives the absolute audio position of the typed text, which is what
    /// "how far behind the speaker are we" has to be measured against.
    private(set) var trimmedTotal = 0
    /// Decode costs seen this session, for the too-slow-model notice below.
    private var decodeCosts: [TimeInterval] = []
    private var warnedSlowModel = false
    /// Last pass's segments in ABSOLUTE sample coordinates (immune to the
    /// buffer trim), for the agreement rule in `decodeAndCommit`.
    private var previousSegments: [(text: String, start: Int, end: Int)] = []
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
        trimmedTotal = 0
        lastDecodeSeconds = 0
        decodeCosts = []
        warnedSlowModel = false
        previousSegments = []
        lastVoiceAt = Date()
        pauseSalvaged = false
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

        // Release the mic NOW — the session is over. The final flush below
        // decodes the already-captured tail from a local copy; keeping the
        // shared `AudioRecorder` live through a multi-second decode lets a
        // hold-to-talk press start a second capture that collides with it.
        let samples = recorder.stop()

        // Final flush: whatever is still untyped is final now — type it
        // wholesale (one clean pass, starting exactly at the typed boundary).
        let tailSamples = samples.count > typedUpto
            ? Array(samples.suffix(from: typedUpto))
            : []
        if !tailSamples.isEmpty {
            await flush(tailSamples)
        }

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
            // The decode is part of the cadence, not extra on top of it: sleep
            // only the remainder of the tick. Sleeping the full tick after a
            // 400 ms decode made every pass ~0.7 s apart and put that straight
            // into how far behind the typed text ran.
            let remaining = max(minSleepSeconds, tickSeconds - lastDecodeSeconds)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard isRunning else { break }
            await tick()
        }
    }

    private func tick() async {
        let now = Date()

        // Hard cap on RETAINED audio, applied before snapshotting. The decode
        // window is never larger than `maxWindowSeconds`, so audio older than
        // that (from the live edge) can never be decoded again. The mic tap
        // appends silence continuously and the post-commit trim only runs
        // after a commit — so during a pause the buffer, and `pendingSeconds`
        // (which arms the force flush), would otherwise grow without bound and
        // the loop never recovers when speech resumes.
        let capSamples = Int(Float(Self.sampleRate) * (maxWindowSeconds + overlapSeconds + 2.0))
        let liveCount = recorder.sampleCount
        if liveCount > capSamples {
            let dropped = recorder.trimSamples(liveCount - capSamples)
            trimmedTotal += dropped
            typedUpto = max(0, typedUpto - dropped)
            decodedUpto = max(0, decodedUpto - dropped)
        }

        let samples = recorder.accumulatedSamples
        let pendingSamples = samples.count - typedUpto
        guard pendingSamples > 0 else { return }          // everything typed: nothing to do
        let pendingSeconds = Float(pendingSamples) / Float(Self.sampleRate)

        // Voice signals read from the AUDIO ITSELF, not from the notch's level
        // ring. The ring is a UI-cadence sample of the mic that the loop does
        // not control, and the questions being asked here are about the exact
        // samples a decode would be spent on.
        //
        //  · `level` — is anyone speaking RIGHT NOW (drives the pause detector).
        //  · `pendingLevel` — is there any speech at all in the audio that has
        //    not been typed yet. Decoding a silent pending region is not merely
        //    wasted: Whisper hallucinates confidently on silence, and the live
        //    path types what it returns.
        let level = Self.peakLevel(of: samples.suffix(Int(Float(Self.sampleRate) * voiceProbeSeconds)))
        let pendingLevel = Self.peakLevel(of: samples.suffix(pendingSamples))
        if level >= silenceLevel { lastVoiceAt = now; pauseSalvaged = false }
        let paused = now.timeIntervalSince(lastVoiceAt) >= pauseFlushDelay

        let enoughNew = Float(samples.count - decodedUpto) / Float(Self.sampleRate) >= minNewAudioSeconds

        // PAUSE HANDLING. The mic keeps feeding silence; without this a resume
        // after a long pause leaves the loop decoding the whole quiet stretch
        // every tick and it never catches up ("stops working after a pause").
        if paused, level < silenceLevel {
            if !pauseSalvaged {
                // One decode to salvage any pre-pause tail that never confirmed
                // — but only if the tail actually contains speech.
                pauseSalvaged = true
                if pendingSeconds >= 0.3, pendingLevel >= silenceLevel {
                    // The tail can no longer change, so there is no second pass
                    // to agree with — commit it on this one.
                    await decodeAndCommit(samples, paused: true, force: true, urgent: true)
                }
                return
            }
            // Tail already handled — collapse the retained silence and resync
            // so the next spoken word starts from a near-empty buffer.
            let keep = Int(Float(Self.sampleRate) * overlapSeconds)
            let cur = recorder.sampleCount
            if cur > keep { trimmedTotal += recorder.trimSamples(cur - keep) }
            typedUpto = recorder.sampleCount
            decodedUpto = recorder.sampleCount
            lastCommitAt = now      // let the normal path handle the resume, not the force flush
            state.partialText = typedText
            return
        }

        // Silence gate. Nothing untyped contains speech → there is nothing to
        // transcribe, however much audio has piled up. Retire it so the buffer
        // (and `pendingSeconds`, which arms the force flush) cannot grow on
        // silence alone; the overlap is kept as left context for the next word.
        if pendingLevel < silenceLevel {
            let keep = Int(Float(Self.sampleRate) * overlapSeconds)
            if samples.count - typedUpto > keep {
                fputs("NotchWhisper[live]: no speech in \(String(format: "%.1f", pendingSeconds))s pending (peak \(String(format: "%.3f", pendingLevel))) — retiring it\n", stderr)
                typedUpto = samples.count - keep
                decodedUpto = max(decodedUpto, typedUpto)
            }
            return
        }

        // Decode triggers: normal cadence (enough new audio), or the
        // pause-flush (the user stopped speaking but a tail is still untyped).
        guard enoughNew || (paused && pendingSeconds >= 0.3) else { return }

        // ANTI-STALL. Text commits only when a segment looks settled; when it
        // does not (Whisper re-segmenting the boundary, drifting timestamps)
        // the tail has to go out anyway or output dies mid-sentence.
        //
        // This is a MODE of the single decode below, never a second decode that
        // pre-empts it. The old loop force-flushed BEFORE the normal pass, so
        // once pending crossed the threshold — which only a commit could undo —
        // the normal path was never reached again and the session spent every
        // remaining tick in the fallback. That deadlock is why live dictation
        // arrived in late bursts instead of flowing.
        let stalled = pendingSeconds >= forcePendingSeconds
            && now.timeIntervalSince(lastCommitAt) >= forceDroughtSeconds
        await decodeAndCommit(samples, paused: paused, force: stalled, urgent: false)
    }

    /// The one decode of a tick, and everything decided from it: what is stable,
    /// what gets typed, and how much audio that retires.
    ///
    /// `force` means the confirmation rule has had its chance and the tail is
    /// overdue (a stall, or the user paused) — commit what the decode produced
    /// rather than keep waiting for a stability signal that may never come.
    @discardableResult
    /// `urgent` waives the two-pass agreement rule for a tail that will never
    /// get a second pass — the salvage decode when the speaker stops. Everywhere
    /// else a guess has to be confirmed before it is typed.
    private func decodeAndCommit(_ samples: [Float], paused: Bool, force: Bool, urgent: Bool) async -> Bool {
        // Bounded sliding window: last `overlapSeconds` of typed audio + all new,
        // but never more than `maxWindowSeconds` (see the field comment).
        let overlapStart = max(0, typedUpto - Int(Float(Self.sampleRate) * overlapSeconds))
        let capStart = max(0, samples.count - Int(Float(Self.sampleRate) * maxWindowSeconds))
        let start = max(overlapStart, capStart)
        guard start < samples.count else { return false }
        let window = Array(samples.suffix(from: start))
        guard Float(window.count) / Float(Self.sampleRate) >= minWindowSeconds else { return false }

        let decodeStarted = Date()
        let segments: [TranscriptionSegment]
        do {
            segments = try await transcriber.liveTranscribe(
                window,
                biasTerms: DictionaryStore.shared.biasingTerms()
            )
        } catch is CancellationError {
            return false                    // stop() tore the session down mid-decode
        } catch {
            // A transient failure mid-dictation: keep listening, retry next
            // tick. (Logged — a silently swallowing loop is undebuggable.)
            fputs("NotchWhisper[live]: decode failed (will retry): \(error)\n", stderr)
            return false
        }
        lastDecodeSeconds = Date().timeIntervalSince(decodeStarted)
        noteDecodeCost(lastDecodeSeconds)
        // stop() may have fired while this decode was in flight (it flips
        // isRunning and releases the recorder but can't interrupt an awaiting
        // tick). Don't type or trim against a torn-down session.
        guard isRunning else { return false }
        decodedUpto = samples.count

        let windowSeconds = Float(window.count) / Float(Self.sampleRate)
        let pendingSeconds = Float(samples.count - typedUpto) / Float(Self.sampleRate)
        fputs("NotchWhisper[live]: pass win=\(String(format: "%.1f", windowSeconds))s"
              + " pending=\(String(format: "%.1f", pendingSeconds))s"
              + " decode=\(String(format: "%.0f", lastDecodeSeconds * 1000))ms"
              + " segs=\(segments.count)\(force ? (urgent ? " force!" : " force") : "")\n", stderr)
        guard !segments.isEmpty else { return false }

        // Live partial for the notch: everything recognized so far this pass.
        let partial = Self.deloop(Self.canonicalize(segments.map(\.text).joined(separator: " ")))
        if !partial.isEmpty {
            state.partialText = Self.canonicalize("\(typedText) \(partial)".trimmingCharacters(in: .whitespaces))
        }

        // WHAT COUNTS AS SETTLED — two independent signals, because the time-lag
        // rule alone almost never fires during continuous speech. Whisper's last
        // segment normally runs right up to the live edge of the window, so
        // `end <= edge - lag` is false on pass after pass and nothing commits.
        //
        //  · Every segment EXCEPT the last is closed: Whisper ends a segment
        //    early only when it decided the phrase finished there, and the audio
        //    after it is already in the same decode. This is what makes text
        //    flow sentence by sentence instead of in late bursts.
        //  · The last segment settles too once it ends `confirmLagSeconds`
        //    before the live edge — or `pauseFlushConfirmLag` while paused,
        //    where no future audio can revise it.
        let stableEnd = paused
            ? windowSeconds - pauseFlushConfirmLag
            : windowSeconds - confirmLagSeconds
        var stable = Array(segments.dropLast())
        if let last = segments.last {
            // The last segment is the one still being spoken. It settles on its
            // own once enough audio has passed it — and under `force`, only if
            // the PREVIOUS pass read the same words at the same place.
            //
            // Two passes agreeing is what separates "the phrase is done" from
            // "the model is guessing at half a phrase". Committing an unsettled
            // segment on a single read is what put "It takes heat to bring it."
            // in front of "It takes heat to bring out the odor." — the guess was
            // typed, then the real phrase arrived and was typed after it.
            if last.end <= stableEnd || (force && (urgent || agreesWithPreviousPass(last, windowStart: start))) {
                stable.append(last)
            }
        }

        // Remembered for the NEXT pass's agreement check, before any trim —
        // absolute coordinates so the trim below cannot invalidate them.
        defer {
            previousSegments = segments.map {
                (text: Self.canonicalize($0.text),
                 start: trimmedTotal + start + Int($0.start * Float(Self.sampleRate)),
                 end: trimmedTotal + start + Int($0.end * Float(Self.sampleRate)))
            }
        }

        // Type every settled segment that carries untyped audio, in order.
        let typedBefore = typedUpto
        for seg in stable {
            let text = Self.deloop(Self.canonicalize(seg.text))
            guard !text.isEmpty else { continue }
            let segStart = start + Int(seg.start * Float(Self.sampleRate))
            let segEnd = start + Int(seg.end * Float(Self.sampleRate))

            if segEnd <= typedUpto + boundaryEpsSamples {
                continue    // pure re-read of already-typed audio
            }
            if segStart >= typedUpto - boundaryEpsSamples {
                // Entirely new audio → type in full. Sample addresses, not
                // text matching, decide this: a repeated phrase must type.
                //
                // One exception, and only for a segment that starts flush
                // against the boundary: a forced commit lands mid-phrase, and
                // the next pass re-reads the same words with timestamps that
                // now place them just after the boundary. Typing that in full
                // duplicates the phrase. A segment starting further into
                // untyped audio is genuinely new and types even if it repeats
                // something said a moment ago.
                let flushAgainstBoundary = segStart <= typedUpto + boundaryEpsSamples
                if flushAgainstBoundary, Self.newChunk(typed: rawAccumulated, fresh: text) == nil {
                    typedUpto = min(samples.count, max(typedUpto, segEnd))
                    continue
                }
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
            typedUpto = min(samples.count, max(typedUpto, segEnd))
        }

        var committed = typedUpto != typedBefore
        // Last resort under `force`: the segments produced nothing usable (all
        // re-reads, or timestamps that put them behind the boundary) but the
        // tail is overdue. Diff the whole window against what is already out
        // and retire the pending audio only if that produced text — otherwise
        // the audio stays pending and the next tick tries again, rather than
        // silently dropping speech.
        if !committed, force {
            let whole = Self.deloop(Self.canonicalize(segments.map(\.text).joined(separator: " ")))
            let isPureReRead = Self.newChunk(typed: rawAccumulated, fresh: whole) == nil
            if !whole.isEmpty,
               urgent || isPureReRead || segments.allSatisfy({ agreesWithPreviousPass($0, windowStart: start) }) {
                committed = !typeTail(whole).isEmpty
                // Retire the audio either way, because the decode DID produce
                // text for it and every word is already at the cursor — whereas
                // keeping it pending is what wedged the old loop: the same audio
                // came back as the same already-typed words on every tick,
                // `typedUpto` never moved, and the tail grew until the session
                // ran seconds behind the speaker.
                //
                // How much to retire depends on whether the decode actually
                // reached the live edge:
                //
                //  · It did → retire the WHOLE window. Stopping at the last
                //    timestamp leaves a sliver pending that the next pass
                //    decodes again and types as a duplicate (measured: it put
                //    "restores health and Store's health and zest" into an
                //    otherwise clean transcript).
                //  · It did not → the decode only covered part of a long tail,
                //    which is what a model too slow for live looks like. Retire
                //    only what it covered; the rest is unheard speech, and
                //    retiring it on the strength of earlier text drops phrases.
                let lastEnd = segments.last.map { start + Int($0.end * Float(Self.sampleRate)) } ?? samples.count
                let reachedEdge = Float(samples.count - lastEnd) / Float(Self.sampleRate) <= confirmLagSeconds + 0.5
                typedUpto = min(samples.count, max(typedUpto, reachedEdge ? samples.count : lastEnd))
            }
        }
        guard committed else { return false }

        lastCommitAt = Date()
        state.partialText = typedText
        fputs("NotchWhisper[live]: commit lag=\(String(format: "%.2f", Float(samples.count - typedUpto) / Float(Self.sampleRate)))s\n", stderr)

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
            trimmedTotal += dropped
            typedUpto -= dropped
            decodedUpto -= dropped
        }
        return true
    }

    /// Did the previous pass read this same segment, at this same place?
    ///
    /// Positions are compared in absolute sample coordinates (the buffer trim
    /// moves everything else), with `agreementSlopSeconds` of tolerance for
    /// Whisper's timestamps drifting as the window grows.
    private func agreesWithPreviousPass(_ segment: TranscriptionSegment, windowStart: Int) -> Bool {
        let text = Self.canonicalize(segment.text)
        guard !text.isEmpty else { return false }
        let startAbs = trimmedTotal + windowStart + Int(segment.start * Float(Self.sampleRate))
        let slop = Int(agreementSlopSeconds * Float(Self.sampleRate))
        return previousSegments.contains { $0.text == text && abs($0.start - startAbs) <= slop }
    }

    /// Live dictation can only be as smooth as one decode pass, and a pass
    /// costs roughly the same whether it carries half a second of speech or
    /// four — most of it is the encoder, whose size is fixed by the model. A
    /// heavy model therefore does not merely lag, it cannot catch up, and no
    /// amount of tuning here changes that. Say so once, with the number,
    /// rather than letting it read as the app being broken.
    ///
    /// (Measured on an M4: a two-second window costs ~1.1 s on Whisper
    /// large-v3 turbo, ~0.5 s on its 632 MB build, ~0.28 s on small, ~0.08 s
    /// on base.)
    private func noteDecodeCost(_ seconds: TimeInterval) {
        guard !warnedSlowModel else { return }
        decodeCosts.append(seconds)
        guard decodeCosts.count >= 4 else { return }
        let mean = decodeCosts.reduce(0, +) / Double(decodeCosts.count)
        guard mean > slowDecodeSeconds else { return }
        warnedSlowModel = true
        let name = ModelRegistry.shared.descriptor(for: settings.modelId).displayName
        state.showToast("\(name) takes about \(String(format: "%.1f", mean)) s per live pass, "
                        + "so dictation will run behind. A lighter model keeps up — see Models.")
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
        let text = Self.deloop(Self.canonicalize(segments.map(\.text).joined(separator: " ")))
        guard !text.isEmpty else { return }
        // The tail begins at the typed boundary, so its text is new; still
        // route through the word-diff to be safe against boundary re-words.
        typeTail(text)
        state.partialText = typedText
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

        // "Capture to history only" suppresses the KEYSTROKES, not the
        // transcript: the session still has to compose its text or the notch
        // ribbon stays blank and History records an empty dictation.
        if autoTypeOverride ?? settings.autoTypeEnabled {
            let path = AutoTyper.type(tail)
            if path == "untrusted", !warnedUntrusted {
                warnedUntrusted = true
                state.showToast("Enable Accessibility for NotchWhisper to type text (System Settings → Privacy & Security).")
            }
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

        // As in `appendAndType`: suppressing the keystrokes must not suppress
        // the transcript. The RETURN VALUE is how the caller learns that this
        // text was consumed and the audio behind it can be retired — returning
        // "" here because typing was off wedged the whole session for anyone
        // running a capture-only profile: the tail never retired, pending grew
        // past the stall threshold, and the loop force-flushed the same audio
        // forever without ever committing.
        if autoTypeOverride ?? settings.autoTypeEnabled {
            let path = AutoTyper.type(tail)
            if path == "untrusted", !warnedUntrusted {
                warnedUntrusted = true
                state.showToast("Enable Accessibility for NotchWhisper to type text (System Settings → Privacy & Security).")
            }
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

    /// Strips Whisper's decoder loop: on quiet or over-long audio it latches
    /// onto a phrase and emits it over and over ("CodeOpenAI CodeOpenAI …"),
    /// which the live path would otherwise type verbatim into the user's
    /// document. A run of the same 1–4 word phrase is cut back to two
    /// occurrences — enough that genuine repetition ("no no", "very very")
    /// survives, and the thresholds are set so ordinary speech never trips it.
    static func deloop(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return s }
        // Longest phrase first: a repeated nine-word sentence has to be caught
        // as a sentence, or the single-word pass shreds it into a shape the
        // sentence pass no longer recognises.
        for size in stride(from: maxLoopPhraseWords, through: 1, by: -1) {
            guard words.count >= size * 2 else { continue }
            // A short phrase repeating is often real speech ("no no no"), a
            // long one never is — so short runs must be longer to count, and
            // are cut back to two rather than one.
            let minRuns = size <= 3 ? 4 : 2
            let keep = size <= 3 ? 2 : 1
            var i = 0
            var out: [String] = []
            while i < words.count {
                guard i + size * minRuns <= words.count else {
                    out.append(contentsOf: words[i...]); break
                }
                let phrase = Array(words[i..<(i + size)])
                var runs = 1
                var j = i + size
                while j + size <= words.count, Array(words[j..<(j + size)]) == phrase {
                    runs += 1
                    j += size
                }
                if runs >= minRuns {
                    for _ in 0..<keep { out.append(contentsOf: phrase) }
                    i = j
                } else {
                    out.append(words[i])
                    i += 1
                }
            }
            words = out
        }
        return words.joined(separator: " ")
    }

    /// Loudest ~85 ms of `probe`, normalized onto the same 0.06…1.0 scale the
    /// recorder publishes for the notch meter. Peak of short frames, not one
    /// RMS over the whole span: the gaps between words would drag a whole-span
    /// average under the silence floor mid-sentence.
    static func peakLevel(of probe: ArraySlice<Float>) -> Float {
        guard !probe.isEmpty else { return 0 }
        let frame = max(1, Int(Float(sampleRate) * 0.085))
        var peak: Float = 0
        var idx = probe.startIndex
        while idx < probe.endIndex {
            let upper = probe.index(idx, offsetBy: frame, limitedBy: probe.endIndex) ?? probe.endIndex
            var sum: Float = 0
            for s in probe[idx..<upper] { sum += s * s }
            let count = probe.distance(from: idx, to: upper)
            if count > 0 {
                peak = max(peak, min(1.0, max(0.06, (sum / Float(count)).squareRoot() * 7.0)))
            }
            idx = upper
        }
        return peak
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
        // Match on the WORDS, not on their punctuation. Whisper moves sentence
        // punctuation around as a window grows — the same word arrives as
        // "pastor." in one pass and "pastor" in the next — and comparing the
        // raw strings made that look like no overlap at all, so the whole
        // re-read phrase was typed a second time.
        let fold = { (words: [Substring]) in
            words.map { $0.lowercased().trimmingCharacters(in: Self.wordEdgePunctuation) }
        }
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
            // The word sitting ON the boundary is the one Whisper was still in
            // the middle of, and it routinely comes back changed once more audio
            // arrives ("linger" → "lingers"). Everything before it matching is
            // enough to call this a re-read.
            for o in stride(from: maxOverlap, through: 2, by: -1)
            where Array(freshFolded.prefix(o).dropLast()) == Array(typedFolded.suffix(o).dropLast()) {
                let tail = freshWords.dropFirst(o)
                return tail.isEmpty ? nil : tail.joined(separator: " ")
            }
            // Near-miss overlap: re-decoding the boundary with more audio often
            // changes a word or two inside a phrase we already typed ("the stale
            // smell of old beer" coming back as "the smell of old beer"). That is
            // still a re-read, and demanding an exact match typed it all again.
            for o in stride(from: maxOverlap, through: fuzzyOverlapMinWords, by: -1) {
                let head = Array(freshFolded.prefix(o))
                let tailOfTyped = Array(typedFolded.suffix(o))
                let agree = zip(head, tailOfTyped).filter { $0 == $1 }.count
                guard Float(agree) / Float(o) >= fuzzyOverlapMinAgreement else { continue }
                let tail = freshWords.dropFirst(o)
                return tail.isEmpty ? nil : tail.joined(separator: " ")
            }
        }
        // No recognizable overlap → type the whole chunk (never drop text).
        return fresh
    }

    /// Punctuation stripped from a word before comparing it to another.
    static let wordEdgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–-")
    /// A fuzzy overlap has to be at least this many words — below it, agreeing
    /// on a word or two means nothing and real speech would be swallowed.
    static let fuzzyOverlapMinWords = 4
    static let fuzzyOverlapMinAgreement: Float = 0.7
}
