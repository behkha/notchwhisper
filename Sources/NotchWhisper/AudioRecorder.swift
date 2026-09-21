import Foundation
@preconcurrency import AVFoundation
import WhisperKit

/// Captures microphone audio via AVAudioEngine, resamples to 16 kHz mono
/// (what Whisper expects) and exposes a live level ring for the notch UI.
///
/// Records from the microphone chosen in Settings (see `AudioInputs`), not
/// necessarily the system default — and moves to the next choice mid-capture
/// if that mic is unplugged or the lid closes on the built-in one.
@MainActor final class AudioRecorder {
    private let state: AppState
    private let settings: Settings

    private var engine: AVAudioEngine?
    /// The device the running capture listens to.
    private(set) var activeDevice: AudioInputDevice?
    private var configObserver: NSObjectProtocol?
    private var inputsObserver: NSObjectProtocol?
    /// Re-opens allowed in one capture — a device that reconfigures itself on
    /// every start must not spin the recorder forever.
    private var reopenBudget = 0
    /// Engines opened for the current capture: 1 unless it had to move to
    /// another mic or reopen. Diagnostic — `--mic-selftest` reads it.
    private(set) var engineOpens = 0
    /// 16 kHz mono capture buffer.
    ///
    /// MUTATED ON THE MIC TAP'S AUDIO THREAD (AVAudioEngine tap callbacks do
    /// NOT run on the main thread) and copied/trimmed from the MainActor by
    /// the live-dictation loop — every access must hold `bufferLock`. The
    /// unguarded version of this buffer is a real data race that corrupts
    /// mid-session: dictation would type the first sentence(s) and then stall
    /// or produce garbage once the concurrent append/copy/trim collided.
    private var audioSamples: [Float] = []
    private let bufferLock = NSLock()
    private let targetRate = Double(WhisperKit.sampleRate)   // 16000
    private var levelRing: [Float] = Array(repeating: 0.12, count: 28)

    init(_ state: AppState, _ settings: Settings) {
        self.state = state
        self.settings = settings
    }

    /// Begin recording. Throws if no microphone can be used (none connected,
    /// the lid closed on the only one) or it is unavailable/denied.
    func start() throws {
        // Defensive: never leak a tap/engine if start is called while already
        // capturing (overlapping record + live-dictation lifecycles).
        if engine != nil { _ = stop() }
        bufferLock.lock()
        audioSamples = []
        bufferLock.unlock()

        let resolution = AudioInputs.resolve(preferredUID: settings.inputDeviceUID,
                                             preferredName: settings.inputDeviceName)
        guard let device = resolution.device else {
            throw AudioInputs.InputError.unavailable(resolution.message ?? "No microphone found.")
        }
        engineOpens = 0
        try open(device)
        // Name the mic in the notch only when it isn't the one chosen.
        state.inputFallbackName = resolution.fallback == nil ? "" : device.name
        reopenBudget = 4
        inputsObserver = NotificationCenter.default.addObserver(
            forName: .audioInputsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputRouteChanged() }
        }
    }

    /// Opens `device` and starts feeding the capture buffer from it.
    private func open(_ device: AudioInputDevice) throws {
        let engine = try AudioInputs.makeEngine(for: device)
        let resampler = MonoResampler(sampleRate: targetRate)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(resampler.convert(buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        activeDevice = device
        engineOpens += 1
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputRouteChanged() }
        }
    }

    /// Releases the engine but keeps what was captured.
    private func close() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        activeDevice = nil
    }

    /// A mic came or went, the lid moved, or the engine reconfigured itself.
    /// A capture stays on its mic while that mic still works — it never jumps
    /// to a device that merely appeared — restarting the engine in place if it
    /// stopped. It moves to the next choice only when the mic can't go on:
    /// unplugged, or the built-in one with the lid now closed. An engine that
    /// followed the system input elsewhere is reopened on its own mic. What
    /// was recorded so far is kept either way.
    private func inputRouteChanged() {
        guard let engine, let current = activeDevice else { return }
        if AudioInputs.resume(engine, on: current) { return }
        let keep = AudioInputs.canKeepUsing(current)
        guard reopenBudget > 0 else {
            if !engine.isRunning { state.inputFallbackName = AppState.noMicrophoneLabel }
            return
        }
        reopenBudget -= 1

        close()
        let next = keep ? current
            : AudioInputs.resolve(preferredUID: settings.inputDeviceUID,
                                  preferredName: settings.inputDeviceName).device
        do {
            guard let next else {
                throw AudioInputs.InputError.unavailable(AppState.noMicrophoneLabel)
            }
            try open(next)
            // A capture that changed mics mid-sentence says which one it is on.
            if next.uid != current.uid { state.inputFallbackName = next.name }
        } catch {
            // Nothing left to hear with. The session stays open so the user
            // can stop it and keep what was said before the mic went away.
            state.inputFallbackName = AppState.noMicrophoneLabel
            Feedback.play(.error)
        }
    }

    /// One converted chunk from the tap. Runs on the audio thread.
    private func process(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        // Audio thread → guard the shared buffer (the live-dictation loop
        // reads and trims it from the MainActor).
        bufferLock.lock()
        audioSamples.append(contentsOf: chunk)
        bufferLock.unlock()

        // RMS level for the notch waveform — computed on the CONVERTED
        // buffer, which is guaranteed float32 (the hardware buffer's
        // floatChannelData can be nil on some devices/formats, which
        // would silently kill the live meter).
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        let norm = min(1.0, max(0.06, rms * 7.0))
        Task { @MainActor in
            self.pushLevel(norm)
            self.state.pushAudio(chunk)   // spectrum analyzer input
        }
    }

    private func pushLevel(_ v: Float) {
        levelRing.removeFirst()
        levelRing.append(v)
        state.levels = levelRing
    }

    /// Whether the mic tap is currently installed (recording in progress).
    var isCapturing: Bool { engine != nil }

    // MARK: - Synthetic capture (offline self-tests)

    /// Begins a capture session fed by `feed(_:)` instead of the microphone.
    /// `--live-selftest` replays a WAV through the real live-dictation loop
    /// with no mic and no permission, so the loop's timing can be measured.
    func startSynthetic() {
        if engine != nil { _ = stop() }
        bufferLock.lock()
        audioSamples = []
        bufferLock.unlock()
    }

    /// Appends one chunk of 16 kHz mono audio as though the mic tap produced
    /// it, including the level ring the live loop reads for its pause detector.
    func feed(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        bufferLock.lock()
        audioSamples.append(contentsOf: chunk)
        bufferLock.unlock()

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        pushLevel(min(1.0, max(0.06, rms * 7.0)))
    }

    /// Copy of everything captured so far (16 kHz mono) — read by the live
    /// dictation loop without stopping the stream. Lock-guarded: the tap
    /// callback appends on the audio thread while this runs on the MainActor.
    var accumulatedSamples: [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioSamples
    }

    /// Current buffer length (lock-guarded, safe from any thread).
    var sampleCount: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioSamples.count
    }

    /// Drop the first `count` already-transcribed samples so a long dictation
    /// session doesn't grow the buffer without bound.
    ///
    /// Returns how many samples were ACTUALLY dropped — possibly fewer than
    /// requested if the buffer shrank concurrently. Callers MUST adjust their
    /// bookkeeping (`typedUpto`, …) by the RETURNED value, never the requested
    /// one, or every sample index desyncs from the buffer and dictation stalls.
    @discardableResult
    func trimSamples(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard audioSamples.count > count else { return 0 }
        audioSamples.removeFirst(count)
        return count
    }

    /// Stop recording and return the captured 16 kHz mono samples.
    func stop() -> [Float] {
        if let inputsObserver { NotificationCenter.default.removeObserver(inputsObserver) }
        inputsObserver = nil
        close()
        state.inputFallbackName = ""
        bufferLock.lock()
        let out = audioSamples
        audioSamples = []
        bufferLock.unlock()
        return out
    }
}
