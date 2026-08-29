import Foundation
import AVFoundation
import WhisperKit

// Mirrors AppDelegate.transcribe(): load the on-disk model and run
// WhisperKit.transcribe(audioArray:) on a real 16 kHz WAV.
let wav = CommandLine.arguments[1]
let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NotchWhisper/Models")

// NW_MODE=offline mirrors the app's offline-first load path exactly
// (Transcriber.loadFolder): load a fully downloaded model straight from its
// on-disk folder with zero network access.
let wk: WhisperKit
let offline = ProcessInfo.processInfo.environment["NW_MODE"] == "offline"
fputs("DEBUG: offline=\(offline)\n", stderr)
if offline {
    let folder = modelDir
        .appendingPathComponent("models")
        .appendingPathComponent("argmaxinc/whisperkit-coreml")
        .appendingPathComponent(ProcessInfo.processInfo.environment["NW_FOLDER"] ?? "openai_whisper-tiny.en", isDirectory: true)
    print("OFFLINE LOAD exists=\(FileManager.default.fileExists(atPath: folder.path)) from \(folder.path)")
    fputs("DEBUG: offline branch, folder=\(folder.path)\n", stderr)
    let cfg = WhisperKitConfig(
        model: nil,
        downloadBase: modelDir,
        modelFolder: folder.path,
        verbose: false,
        logLevel: .none,
        load: true,
        download: false
    )
    print("cfg: model=\(cfg.model ?? "nil") modelFolder=\(cfg.modelFolder ?? "nil") download=\(String(describing: cfg.download)) load=\(String(describing: cfg.load))")
    fflush(stdout)
    wk = try await WhisperKit(cfg)
} else {
    let cfg = WhisperKitConfig(model: "whisper-base", downloadBase: modelDir, verbose: false, logLevel: .none, load: true)
    wk = try await WhisperKit(cfg)
}
print("MODEL LOADED OK")
fflush(stdout)

// Load WAV as 16 kHz mono Float array, exactly like AudioRecorder would deliver.
let url = URL(fileURLWithPath: wav)
let file = try AVAudioFile(forReading: url)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let conv = AVAudioConverter(from: file.processingFormat, to: format)!
let capacity = AVAudioFrameCount(file.length) + 4096
var samples: [Float] = []
while true {
    let readFrames = AVAudioFrameCount(min(Int(file.length - file.framePosition), 4096))
    guard readFrames > 0 else { break }
    let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readFrames)!
    try file.read(into: inBuffer, frameCount: readFrames)
    var convError: NSError?
    let outSlice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames * 2)!
    conv.convert(to: outSlice, error: &convError) { _, outStatus in
        outStatus.pointee = .haveData
        return inBuffer
    }
    if let ch = outSlice.floatChannelData {
        let n = Int(outSlice.frameLength)
        samples.append(contentsOf: Array(UnsafeBufferPointer(start: ch[0], count: n)))
    }
}

let opts = DecodingOptions(verbose: false, task: .transcribe, language: nil, temperature: 0.0, temperatureFallbackCount: 3, skipSpecialTokens: true, withoutTimestamps: true)
let results = try await wk.transcribe(audioArray: samples, decodeOptions: opts)
let text = results.map { $0.text }.joined(separator: "\n")
print("TRANSCRIBED: \(text)")
