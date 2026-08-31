import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import WhisperKit

/// Decodes a user-picked audio (or video) file into the 16 kHz mono float
/// samples every engine in the app consumes — exactly the format the mic
/// recorder produces, so file transcription reuses the whole existing
/// pipeline (dictionary bias, correction pass, history).
enum AudioFileImport {

    /// Sample rate every engine expects (Whisper and Qwen3-ASR alike).
    static let sampleRate: Double = Double(WhisperKit.sampleRate)   // 16000

    /// Extensions accepted by the open panel and by drag-and-drop.
    static let allowedExtensions = [
        "wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "flac",
        "mp4", "m4v", "mov", "au", "snd",
    ]

    /// Content types for `NSOpenPanel.allowedContentTypes`. The two supertypes
    /// cover most containers; the per-extension types catch formats whose UTI
    /// doesn't declare conformance (FLAC on older systems).
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.audio, .movie]
        types += allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        // De-duplicate while keeping order.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    static func looksSupported(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case noAudioTrack
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn't read that file: \(why)"
            case .noAudioTrack:        return "That file has no audio track."
            case .empty:               return "That file contains no audio."
            }
        }
    }

    /// Decode `url` to 16 kHz mono floats.
    ///
    /// Two paths, in order:
    ///  1. WhisperKit's `AudioProcessor` (ExtAudioFile) — handles wav / mp3 /
    ///     m4a / aiff / caf / flac and resamples in 10-minute slices, so peak
    ///     memory stays bounded on long recordings.
    ///  2. `AVAssetReader` over the file's audio track — the fallback for
    ///     containers `AVAudioFile` refuses to open (mp4/mov video, some m4a
    ///     variants). Same output format.
    static func loadSamples(from url: URL) async throws -> [Float] {
        let path = url.path
        let viaAudioFile = await Task.detached(priority: .userInitiated) { () -> [Float]? in
            try? AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        if let viaAudioFile, !viaAudioFile.isEmpty { return viaAudioFile }

        let samples = try await decodeAudioTrack(url)
        guard !samples.isEmpty else { throw ImportError.empty }
        return samples
    }

    /// AVAssetReader fallback: pull the audio track out of any AVFoundation
    /// -readable container, converted straight to 16 kHz mono float32.
    private static func decodeAudioTrack(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw ImportError.noAudioTrack }

        return try await Task.detached(priority: .userInitiated) { () -> [Float] in
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) }
            catch { throw ImportError.unreadable(error.localizedDescription) }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ImportError.unreadable("unsupported audio encoding")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw ImportError.unreadable(reader.error?.localizedDescription ?? "reader failed to start")
            }

            var out: [Float] = []
            while let sample = output.copyNextSampleBuffer() {
                if let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(
                        block, atOffset: 0, lengthAtOffsetOut: nil,
                        totalLengthOut: &length, dataPointerOut: &pointer
                    )
                    if let pointer, length >= MemoryLayout<Float>.size {
                        let count = length / MemoryLayout<Float>.size
                        pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                            out.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                        }
                    }
                }
                CMSampleBufferInvalidate(sample)
                if Task.isCancelled { reader.cancelReading(); return out }
            }

            if reader.status == .failed {
                throw ImportError.unreadable(reader.error?.localizedDescription ?? "decode failed")
            }
            return out
        }.value
    }

    /// "3:42" / "1:04:07" for a sample count at 16 kHz.
    static func durationLabel(samples: Int) -> String {
        durationLabel(seconds: Double(samples) / sampleRate)
    }

    static func durationLabel(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
