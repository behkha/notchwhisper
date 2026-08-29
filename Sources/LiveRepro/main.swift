import Foundation
import AVFoundation
import WhisperKit

// Verification harness for the FIXED live-dictation logic (mirrors the new
// LiveTranscriber.tick()): sample-addressed typing, pause-flush, trim only
// after typing. Replays a 16 kHz WAV in mic-sized chunks, then simulates the
// user PAUSING (2 s of no new audio) to verify the pending tail types.

let sampleRate = 16000.0
let minNewAudioSeconds: Float = 0.25
let overlapSeconds: Float = 0.9
let confirmLagSeconds: Float = 0.5
let pauseFlushDelay: TimeInterval = 1.2
let pauseFlushConfirmLag: Float = 0.12
let boundaryEpsSamples = 1_600
let deepCrossSeconds: Float = 0.5
let deepCrossForceSeconds: Float = 1.0

func canonicalize(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func newChunk(typed: String, fresh: String) -> String? {
    let freshWords = fresh.split(separator: " ")
    guard !freshWords.isEmpty else { return nil }
    guard !typed.isEmpty else { return fresh }
    let typedWords = typed.split(separator: " ")
    if freshWords.count <= typedWords.count,
       Array(freshWords) == Array(typedWords.suffix(freshWords.count)) {
        return nil
    }
    let maxOverlap = min(typedWords.count, freshWords.count - 1)
    if maxOverlap > 0 {
        for o in stride(from: maxOverlap, through: 1, by: -1)
        where Array(freshWords.prefix(o)) == Array(typedWords.suffix(o)) {
            let tail = freshWords.dropFirst(o)
            return tail.isEmpty ? nil : tail.joined(separator: " ")
        }
    }
    return fresh
}

guard CommandLine.arguments.count > 1 else {
    print("usage: LiveRepro <16kHz.wav>"); exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url)
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
let totalFrames = AVAudioFrameCount(file.length)
let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames)!
try file.read(into: inBuf, frameCount: totalFrames)
let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: totalFrames + 1024)!
var err: NSError?
var fed = false
conv.convert(to: out, error: &err) { _, st in
    if fed { st.pointee = .noDataNow; return nil }
    fed = true
    st.pointee = .haveData
    return inBuf
}
guard let ch = out.floatChannelData else { fatalError("no float data") }
var all: [Float] = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
print("loaded \(all.count) samples = \(String(format: "%.2f", Double(all.count) / sampleRate))s")

let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NotchWhisper/Models")
let cfg = WhisperKitConfig(model: "whisper-base", downloadBase: modelDir, verbose: false, logLevel: .none, load: true)
let wk = try await WhisperKit(cfg)
print("model loaded")

func liveDecode(_ window: [Float]) async throws -> [TranscriptionSegment] {
    let opts = DecodingOptions(
        verbose: false, task: .transcribe, language: nil,
        temperature: 0.0, temperatureFallbackCount: 0,
        usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: false
    )
    let results = try await wk.transcribe(audioArray: window, decodeOptions: opts)
    return results.flatMap { $0.segments }
}

final class Mic {
    private(set) var samples: [Float] = []
    var count: Int { samples.count }
    func append(_ s: [Float]) { samples.append(contentsOf: s) }
    func suffix(from i: Int) -> [Float] { Array(samples.suffix(from: i)) }
    func trim(_ n: Int) { if n > 0, n < samples.count { samples.removeFirst(n) } }
}

let mic = Mic()
var typedUpto = 0
var decodedUpto = 0
var lastBufferSize = 0
var lastAudioGrowth = Date()
var typedText = ""
var typedDeltas: [String] = []
var tickIndex = 0

func typeTail(_ rawNewText: String) {
    guard let chunk = newChunk(typed: typedText, fresh: rawNewText), !chunk.isEmpty else { return }
    typedDeltas.append(chunk)
    typedText = canonicalize("\(typedText) \(chunk)".trimmingCharacters(in: .whitespaces))
}
func appendAndType(_ text: String) {
    typedDeltas.append(text)
    typedText = canonicalize("\(typedText) \(text)".trimmingCharacters(in: .whitespaces))
}

func tick(pausedOverride: Bool? = nil) async {
    let samplesCount = mic.count
    let now = Date()
    if samplesCount > lastBufferSize { lastAudioGrowth = now }
    lastBufferSize = samplesCount

    let pendingSamples = samplesCount - typedUpto
    guard pendingSamples > 0 else { return }
    let pendingSeconds = Float(pendingSamples) / Float(sampleRate)
    let paused = pausedOverride ?? (now.timeIntervalSince(lastAudioGrowth) >= pauseFlushDelay)
    let enoughNew = Float(samplesCount - decodedUpto) / Float(sampleRate) >= minNewAudioSeconds

    // (silence gate not simulated — harness has no mic levels)
    guard enoughNew || (paused && pendingSeconds >= 0.3) else { return }

    let start = max(0, typedUpto - Int(Float(sampleRate) * overlapSeconds))
    guard start < samplesCount else { return }
    let window = mic.suffix(from: start)
    guard !window.isEmpty else { return }

    let segments: [TranscriptionSegment]
    do {
        segments = try await liveDecode(window)
    } catch {
        print("decode error: \(error)")
        return
    }
    decodedUpto = samplesCount
    guard !segments.isEmpty else { return }

    let windowSeconds = Float(window.count) / Float(sampleRate)
    let stableEnd = (paused && !enoughNew) ? windowSeconds - pauseFlushConfirmLag
                                           : windowSeconds - confirmLagSeconds
    let stable = segments.filter { $0.end <= stableEnd }
    guard !stable.isEmpty else { return }

    for seg in stable {
        let text = canonicalize(seg.text)
        guard !text.isEmpty else { continue }
        let segStart = start + Int(seg.start * Float(sampleRate))
        let segEnd = start + Int(seg.end * Float(sampleRate))
        if segEnd <= typedUpto + boundaryEpsSamples { continue }
        if segStart >= typedUpto - boundaryEpsSamples {
            appendAndType(text)
        } else if segStart >= typedUpto - Int(deepCrossSeconds * Float(sampleRate)) {
            typeTail(text)
        } else if segEnd - typedUpto > Int(deepCrossForceSeconds * Float(sampleRate)) {
            typeTail(text)
        } else {
            continue
        }
        typedUpto = max(typedUpto, segEnd)
    }

    let trim = max(0, typedUpto - Int(Float(sampleRate) * overlapSeconds))
    if trim > 0 {
        mic.trim(trim)
        typedUpto -= trim
        decodedUpto -= trim
        lastBufferSize -= trim
    }
}

// Phase 1: feed audio in mic-sized chunks, tick after each (real-time-ish).
let chunkSize = Int(0.23 * sampleRate)
var pos = 0
while pos < all.count {
    let end = min(pos + chunkSize, all.count)
    mic.append(Array(all[pos..<end]))
    pos = end
    tickIndex += 1
    await tick()
    print("tick \(tickIndex): buf \(String(format: "%.1f", Double(mic.count)/sampleRate))s · typed: \"\(typedText)\"")
}

// Phase 2: PAUSE — 6 ticks with NO new audio (user stopped speaking).
print("--- pause phase (no new audio) ---")
for _ in 0..<6 {
    tickIndex += 1
    await tick()
    print("tick \(tickIndex): buf \(String(format: "%.1f", Double(mic.count)/sampleRate))s · typed: \"\(typedText)\"")
}

print("\n================ RESULT ================")
print("TYPED (\(typedDeltas.count) deltas):")
for d in typedDeltas { print("  + \"\(d)\"") }
print("FINAL TYPED TEXT: \"\(typedText)\"")
