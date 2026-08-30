import Foundation
import SwiftUI

enum NotchMode: Equatable {
    case idle
    case recording
    case transcribing
    /// Live dictation: a continuous session that types as you speak (Settings →
    /// General → "Live dictation"). Rendered like recording, plus the live partial
    /// transcript in the notch ribbon.
    case dictating
    /// Local LLM post-processing of a finished transcription (Settings →
    /// Local LLM). The notch shows the "Improving…" state so dictation and
    /// processing read as one continuous action.
    case improving
    case done
    case error
}

/// Shared, observable app state driving the notch UI, the main window, and
/// the logic layers. Single source of truth.
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Recording / live UI
    @Published var mode: NotchMode = .idle
    @Published var partialText: String = ""
    @Published var lastText: String = ""
    @Published var levels: [Float] = Array(repeating: 0.12, count: 28)
    /// Latest raw 16 kHz mono chunk from the recorder — feeds the spectrum
    /// analyzer behind the notch bars (pitch → which bars move).
    @Published var audioChunk: [Float] = []
    @Published var recordingStart: Date? = nil
    @Published var statusMessage: String = ""

    // MARK: Model lifecycle
    @Published var modelStatus: ModelStatus = .unknown
    /// True while a model is being loaded into memory (distinct from
    /// downloading). Drives the "Loading model…" progress bar in the notch,
    /// Home and Settings.
    @Published var isLoadingModel = false
    /// 0…1 progress of the current model load (stepped: specialize → load →
    /// tokenizer → ready). Not byte-accurate — WhisperKit gives no finer signal.
    @Published var modelLoadProgress: Double = 0
    /// Human phase label for the load, e.g. "Specializing for the Neural Engine…".
    @Published var modelLoadPhase: String = ""
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadLabel: String = ""
    /// Model id currently being downloaded (nil when idle). Lets the UI tell
    /// "this model's download" apart from any other download in progress.
    @Published var downloadingModelId: String? = nil
    /// Byte-accurate download stats sampled from disk while downloading.
    @Published var downloadBytesDone: Int64 = 0
    /// Total bytes of the current download (0 = unknown).
    @Published var downloadBytesTotal: Int64 = 0
    /// Smoothed bytes/second (0 = not measured yet).
    @Published var downloadSpeedBps: Double = 0
    /// Estimated seconds remaining (0 = unknown).
    @Published var downloadEtaSeconds: Double = 0

    // MARK: Download stats helpers

    /// Clears all per-download stats. Called when a new download starts.
    func resetDownloadStats() {
        downloadProgress = 0
        downloadBytesDone = 0
        downloadBytesTotal = 0
        downloadSpeedBps = 0
        downloadEtaSeconds = 0
    }

    /// Best-available progress fraction.
    ///
    /// When a real byte total is known (from the HF API) the BYTE fraction is
    /// the source of truth — WhisperKit's own `downloadProgress` is file-count
    /// based (one unit per file regardless of size), so it races to ~50% on the
    /// many tiny config files and then crawls through the multi-hundred-MB
    /// weight files, which reads as a stuck/lying bar. The byte fraction is held
    /// just below 100% until WhisperKit confirms every file finished, so the bar
    /// never claims "done" while data is still moving.
    var displayProgress: Double {
        guard downloadBytesTotal > 0 else { return downloadProgress }
        let byteFraction = min(1, Double(downloadBytesDone) / Double(downloadBytesTotal))
        if downloadProgress >= 1.0 { return 1.0 }
        return min(byteFraction, 0.995)
    }

    /// One-line download summary, e.g.
    /// "412 MB / 1.4 GB · 29% · 8.2 MB/s · ~2 min 10 s left".
    var downloadDetailText: String {
        var parts: [String] = []
        if downloadBytesTotal > 0 {
            parts.append("\(formatBytes(downloadBytesDone)) / \(formatBytes(downloadBytesTotal))")
            parts.append("\(Int((displayProgress * 100).rounded()))%")
        } else if downloadBytesDone > 0 {
            parts.append(formatBytes(downloadBytesDone))
        }
        if downloadSpeedBps > 1024 {
            parts.append("\(formatBytes(Int64(downloadSpeedBps)))/s")
        }
        if downloadEtaSeconds > 1, downloadBytesTotal > 0, downloadBytesDone < downloadBytesTotal {
            parts.append("~\(formatEta(downloadEtaSeconds)) left")
        }
        return parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatEta(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    // MARK: Live level meter (main window) — same data, read by both views.
    var levelArray: [Float] { levels }

    // MARK: Convenience accessors to stores
    var busy: Bool {
        mode == .recording || mode == .transcribing || mode == .dictating
            || mode == .improving || isDownloading
    }

    func showToast(_ message: String) {
        statusMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { if self?.statusMessage == message { self?.statusMessage = "" } }
        }
    }

    // MARK: - Level helper used by the recorder
    func pushLevels(_ newLevels: [Float]) {
        levels = newLevels
    }

    /// Push a raw 16 kHz mono audio chunk for the spectrum analyzer.
    func pushAudio(_ chunk: [Float]) {
        audioChunk = chunk
    }
}

enum ModelStatus: Equatable {
    case unknown
    case loading
    case ready
    case downloading
    case error(String)
}
