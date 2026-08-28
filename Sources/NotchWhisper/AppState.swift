import Foundation
import SwiftUI

enum NotchMode: Equatable {
    case idle
    case recording
    case transcribing
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
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadLabel: String = ""

    // MARK: Live level meter (main window) — same data, read by both views.
    var levelArray: [Float] { levels }

    // MARK: Convenience accessors to stores
    var busy: Bool { mode == .recording || mode == .transcribing || isDownloading }

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
