import Foundation
import AVFoundation
import WhisperKit

// Headless WhisperKit transcription harness.
//
//   swift run TranscribeTest <audio.wav>
//   NW_MODE=offline NW_FOLDER=openai_whisper-base swift run TranscribeTest <audio.wav>
//
// The llama.cpp / Qwen3-ASR engine has its own headless path:
//   swift run NotchWhisper --llama-selftest <model.gguf> <mmproj.gguf> <audio.wav> ["context"]

/// Load a WAV as a 16 kHz mono Float array, exactly like AudioRecorder delivers.
func loadWav16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: file.processingFormat, to: format)!
    let ratio = 16000.0 / file.processingFormat.sampleRate
    var samples: [Float] = []
    while true {
        let readFrames = AVAudioFrameCount(min(Int(file.length - file.framePosition), 16384))
        guard readFrames > 0 else { break }
        let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readFrames)!
        try file.read(into: inBuffer, frameCount: readFrames)
        var convError: NSError?
        // Exact output capacity so the converter can't over-pull the input
        // block and duplicate every sample.
        let outCap = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 16
        let outSlice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap)!
        var provided = false
        conv.convert(to: outSlice, error: &convError) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let ch = outSlice.floatChannelData {
            let n = Int(outSlice.frameLength)
            samples.append(contentsOf: Array(UnsafeBufferPointer(start: ch[0], count: n)))
        }
    }
    return samples
}

let args = CommandLine.arguments
let wav = args[1]
let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NotchWhisper/Models")

let wk: WhisperKit
let offline = ProcessInfo.processInfo.environment["NW_MODE"] == "offline"
fputs("DEBUG: offline=\(offline)\n", stderr)
if offline {
    let folder = modelDir
        .appendingPathComponent("models")
        .appendingPathComponent("argmaxinc/whisperkit-coreml")
        .appendingPathComponent(ProcessInfo.processInfo.environment["NW_FOLDER"] ?? "openai_whisper-tiny.en", isDirectory: true)
    print("OFFLINE LOAD exists=\(FileManager.default.fileExists(atPath: folder.path)) from \(folder.path)")
    let cfg = WhisperKitConfig(
        model: nil,
        downloadBase: modelDir,
        modelFolder: folder.path,
        verbose: false,
        logLevel: .none,
        load: true,
        download: false
    )
    wk = try await WhisperKit(cfg)
} else {
    let cfg = WhisperKitConfig(model: "whisper-base", downloadBase: modelDir, verbose: false, logLevel: .none, load: true)
    wk = try await WhisperKit(cfg)
}
print("MODEL LOADED OK")
fflush(stdout)

let samples = try loadWav16k(wav)
let opts = DecodingOptions(verbose: false, task: .transcribe, language: nil, temperature: 0.0, temperatureFallbackCount: 3, skipSpecialTokens: true, withoutTimestamps: true)
let results = try await wk.transcribe(audioArray: samples, decodeOptions: opts)
let text = results.map { $0.text }.joined(separator: "\n")
print("TRANSCRIBED: \(text)")
