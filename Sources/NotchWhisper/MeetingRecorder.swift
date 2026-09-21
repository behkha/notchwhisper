import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Long-form capture for meetings (spec 09): the microphone and, when the
/// user allows it, the Mac's own output audio, written incrementally to a
/// two-channel 16 kHz WAV so a two-hour meeting never lives in memory.
///
/// Channel 0 is the mic, channel 1 the system — kept apart on disk even though
/// v1 transcribes the mix, because "who spoke" is trivially "which channel had
/// energy" once diarization arrives.
///
/// `AudioRecorder` is deliberately not reused: it is tuned for short dictation
/// and the live loop's trim protocol, and this path needs neither.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum Source: String, Codable {
        case micOnly = "mic"
        case micAndSystem = "mic+system"

        var label: String {
            switch self {
            case .micOnly:      return "Microphone only"
            case .micAndSystem: return "Microphone + Mac audio"
            }
        }
    }

    enum RecorderError: LocalizedError {
        case noDisplay, converter, alreadyRecording
        var errorDescription: String? {
            switch self {
            case .noDisplay:        return "No display to capture audio from."
            case .converter:        return "The audio converter could not be created."
            case .alreadyRecording: return "A meeting is already being recorded."
            }
        }
    }

    static let sampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    /// Latest microphone level, 0…1, on the main queue — for the meter.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Something degraded mid-recording (system capture stopped, mic route
    /// changed). The recording keeps going; the user is told.
    var onNotice: (@Sendable (String) -> Void)?

    private(set) var isRecording = false
    private(set) var source: Source = .micOnly
    private(set) var fileURL: URL?

    /// The microphone chosen in Settings (UID and name; nil UID = Automatic).
    /// Set before `start`; read again whenever the mic has to be reopened.
    var preferredInput: (uid: String?, name: String?) = (nil, nil)

    private var engine: AVAudioEngine?
    private var micDevice: AudioInputDevice?
    private var micConverter: AVAudioConverter?
    private var stream: SCStream?
    private var systemConverter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var inputsObserver: NSObjectProtocol?
    /// Mic re-opens are serialized here, and rate-limited: a device that
    /// reconfigures itself on every start must not spin the recorder.
    private let routeQueue = DispatchQueue(label: "com.behkha.notchwhisper.meeting.route")
    private var recentReopens: [Date] = []

    private let lock = NSLock()
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    private var systemActive = false
    private var writer: WAVWriter?
    private var flushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "com.behkha.notchwhisper.meeting.flush", qos: .utility)
    private let systemQueueLabel = DispatchQueue(label: "com.behkha.notchwhisper.meeting.system", qos: .userInitiated)
    private var lastHeaderFlush = Date()

    /// Frames written so far — the recording's true length even after a crash.
    var framesWritten: Int { writer?.frames ?? 0 }

    /// Scoped locking, so the async entry points never hold `NSLock` across a
    /// suspension point.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Lifecycle

    /// Opens the file and the microphone; adds system audio when asked and
    /// permitted. A refused Screen Recording permission degrades to mic-only
    /// with a notice rather than failing the meeting.
    func start(to url: URL, includeSystemAudio: Bool) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let writer = try WAVWriter(url: url, channels: 2, sampleRate: Int(Self.sampleRate))
        locked {
            self.writer = writer
            micQueue = []
            systemQueue = []
            systemActive = false
        }
        fileURL = url
        try startMic()
        source = .micOnly
        if includeSystemAudio {
            do {
                try await startSystemCapture()
                source = .micAndSystem
            } catch {
                fputs("MeetingRecorder: system audio unavailable: \(error)\n", stderr)
                onNotice?("The Mac's audio couldn't be captured, so only the microphone is being recorded. \(error.localizedDescription)")
            }
        }
        isRecording = true
        lastHeaderFlush = Date()
        startFlushTimer()
    }

    /// Stops everything, drains what is queued and closes the file. Returns
    /// the recorded length in seconds.
    func stop() async -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false
        flushTimer?.cancel()
        flushTimer = nil
        stopMic()
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        locked { systemActive = false }
        flushQueue.sync { self.flush(final: true) }
        let frames: Int = locked {
            let frames = writer?.frames ?? 0
            writer?.close()
            writer = nil
            return frames
        }
        return Double(frames) / Self.sampleRate
    }

    // MARK: Microphone

    private func startMic() throws {
        let resolution = AudioInputs.resolve(preferredUID: preferredInput.uid,
                                             preferredName: preferredInput.name)
        guard let device = resolution.device else {
            throw AudioInputs.InputError.unavailable(resolution.message ?? "No microphone found.")
        }
        let engine = try AudioInputs.makeEngine(for: device)
        micConverter = nil
        // `format: nil` — a routed input's hardware format is the device's,
        // not the node's output bus; naming the wrong one throws an exception.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convert(buffer, with: &self.micConverter)
            guard !samples.isEmpty else { return }
            self.lock.lock()
            self.micQueue.append(contentsOf: samples)
            self.lock.unlock()
            var sum: Float = 0
            for s in samples { sum += s * s }
            let rms = (sum / Float(samples.count)).squareRoot()
            let level = min(1, max(0.04, rms * 7))
            if let onLevel = self.onLevel {
                DispatchQueue.main.async { onLevel(level) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        micDevice = device
        if resolution.fallback != nil, let message = resolution.message {
            onNotice?(message)
        }
        // AirPods connecting, a dock unplugged, the lid closing on the
        // built-in mic: move to the next choice rather than silently
        // recording nothing for the rest of the meeting.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.routeQueue.async { self.micRouteChanged() }
        }
        if inputsObserver == nil {
            inputsObserver = NotificationCenter.default.addObserver(
                forName: .audioInputsChanged, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.routeQueue.async { self.micRouteChanged() }
            }
        }
    }

    private func micRouteChanged() {
        guard isRecording, let engine, let current = micDevice else { return }
        // Routing reconfigures the engine a moment after it starts, which can
        // stop it with nothing actually changed — restart it in place.
        if AudioInputs.resume(engine, on: current) { return }
        let now = Date()
        recentReopens = recentReopens.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard recentReopens.count <= 3 else { return }
        stopMic(keepObserver: true)
        do {
            try startMic()
            if micDevice?.uid != current.uid {
                onNotice?("The microphone changed mid-meeting — recording continues on \(micDevice?.name ?? "the new one").")
            }
        } catch {
            onNotice?("The microphone went away and no other could be opened: \(error.localizedDescription)")
        }
    }

    private func stopMic(keepObserver: Bool = false) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        micDevice = nil
        micConverter = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if !keepObserver, let inputsObserver {
            NotificationCenter.default.removeObserver(inputsObserver)
            self.inputsObserver = nil
        }
    }

    // MARK: System audio (ScreenCaptureKit)

    /// Audio-only capture of the whole display. No frames are ever wanted;
    /// the video configuration is the smallest ScreenCaptureKit accepts.
    private func startSystemCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(Self.sampleRate)
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueueLabel)
        try await stream.startCapture()
        self.stream = stream
        locked { systemActive = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording, CMSampleBufferIsValid(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        let samples = convert(buffer, with: &systemConverter)
        guard !samples.isEmpty else { return }
        lock.lock()
        systemQueue.append(contentsOf: samples)
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        systemActive = false
        lock.unlock()
        self.stream = nil
        if isRecording {
            onNotice?("The Mac's audio stopped being captured: \(error.localizedDescription). The microphone is still recording.")
        }
    }

    // MARK: Conversion

    /// Any input format → 16 kHz mono float. The converter is rebuilt when the
    /// input format changes (a new mic, a stream renegotiation).
    private func convert(_ buffer: AVAudioPCMBuffer, with converter: inout AVAudioConverter?) -> [Float] {
        let target = Self.targetFormat
        let input = buffer.format
        if input.sampleRate == target.sampleRate, input.channelCount == 1,
           input.commonFormat == .pcmFormatFloat32, let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        if converter == nil || converter?.inputFormat != input {
            converter = AVAudioConverter(from: input, to: target)
        }
        guard let converter else { return [] }
        let ratio = target.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    // MARK: Writing

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.flush(final: false) }
        timer.resume()
        flushTimer = timer
    }

    /// Moves queued audio to disk as interleaved frames. The two sources run
    /// on their own clocks: normally the shorter queue sets the pace; when one
    /// falls more than a second behind (a source that dropped out) the other is
    /// padded so time keeps moving instead of stalling the file.
    private func flush(final: Bool) {
        lock.lock()
        guard let writer else { lock.unlock(); return }
        let micCount = micQueue.count
        let systemCount = systemQueue.count
        let frames: Int
        if !systemActive && !final {
            frames = micCount
        } else if final || abs(micCount - systemCount) > Int(Self.sampleRate) {
            frames = max(micCount, systemCount)
        } else {
            frames = min(micCount, systemCount)
        }
        guard frames > 0 else { lock.unlock(); return }
        var mic = Array(micQueue.prefix(frames))
        var system = Array(systemQueue.prefix(frames))
        micQueue.removeFirst(min(frames, micCount))
        systemQueue.removeFirst(min(frames, systemCount))
        lock.unlock()
        if mic.count < frames { mic += [Float](repeating: 0, count: frames - mic.count) }
        if system.count < frames { system += [Float](repeating: 0, count: frames - system.count) }
        writer.append(left: mic, right: system)
        // The header carries the true length every ~10 s, so a crashed
        // recording is still a playable, transcribable file.
        if final || Date().timeIntervalSince(lastHeaderFlush) > 10 {
            writer.flush()
            lastHeaderFlush = Date()
        }
    }
}

// MARK: - WAV writer

/// 16-bit PCM WAV, appended incrementally; `flush()` rewrites the sizes in the
/// header so the file is valid at every checkpoint.
final class WAVWriter {
    private let handle: FileHandle
    private let channels: Int
    private let sampleRate: Int
    private(set) var frames = 0
    private var closed = false

    init(url: URL, channels: Int, sampleRate: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        self.channels = channels
        self.sampleRate = sampleRate
        handle.write(Self.header(channels: channels, sampleRate: sampleRate, dataBytes: 0))
    }

    func append(left: [Float], right: [Float]) {
        guard !closed else { return }
        let count = min(left.count, right.count)
        var data = Data(capacity: count * channels * 2)
        for i in 0..<count {
            var l = Int16(max(-1, min(1, left[i])) * 32_767)
            var r = Int16(max(-1, min(1, right[i])) * 32_767)
            withUnsafeBytes(of: &l) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &r) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        frames += count
    }

    func flush() {
        guard !closed else { return }
        let dataBytes = frames * channels * 2
        let end = handle.offsetInFile
        handle.seek(toFileOffset: 0)
        handle.write(Self.header(channels: channels, sampleRate: sampleRate, dataBytes: dataBytes))
        handle.seek(toFileOffset: end)
        try? handle.synchronize()
    }

    func close() {
        guard !closed else { return }
        flush()
        closed = true
        try? handle.close()
    }

    private static func header(channels: Int, sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: 44)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)                               // PCM
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * channels * 2)       // byte rate
        u16(channels * 2)                    // block align
        u16(16)                              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return data
    }
}
