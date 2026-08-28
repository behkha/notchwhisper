import Foundation
@preconcurrency import AVFoundation
import WhisperKit

/// Captures microphone audio via AVAudioEngine, resamples to 16 kHz mono
/// (what Whisper expects) and exposes a live level ring for the notch UI.
@MainActor final class AudioRecorder {
    private let state: AppState
    private let settings: Settings

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var audioSamples: [Float] = []
    private let targetRate = Double(WhisperKit.sampleRate)   // 16000
    private var levelRing: [Float] = Array(repeating: 0.12, count: 28)

    init(_ state: AppState, _ settings: Settings) {
        self.state = state
        self.settings = settings
    }

    /// Begin recording. Throws if the mic is unavailable/denied.
    func start() throws {
        audioSamples = []
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFmt = input.inputFormat(forBus: 0)
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: hwFmt, to: outFmt) else {
            throw RecorderError.converterInit
        }
        self.converter = converter
        self.engine = engine

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: capacity
        ) else { return }

        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, statusPtr in
            statusPtr.pointee = .haveData
            return buffer
        }
        if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
            let ptr = ch[0]
            let count = Int(outBuf.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))
            audioSamples.append(contentsOf: chunk)

            // RMS level for the notch waveform — computed on the CONVERTED
            // buffer, which is guaranteed float32 (the hardware buffer's
            // floatChannelData can be nil on some devices/formats, which
            // would silently kill the live meter).
            var sum: Float = 0
            for i in 0..<count { let s = ptr[i]; sum += s * s }
            let rms = sqrt(sum / Float(count))
            let norm = min(1.0, max(0.06, rms * 7.0))
            Task { @MainActor in
                self.pushLevel(norm)
                self.state.pushAudio(chunk)   // spectrum analyzer input
            }
        }
    }

    private func pushLevel(_ v: Float) {
        levelRing.removeFirst()
        levelRing.append(v)
        state.levels = levelRing
    }

    /// Stop recording and return the captured 16 kHz mono samples.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        let out = audioSamples
        audioSamples = []
        return out
    }

    enum RecorderError: Error { case converterInit }
}
