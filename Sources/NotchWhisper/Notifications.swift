import Foundation

/// Centralized notification names used across the app to keep the SwiftUI
/// views and the AppKit/Carbon layers loosely coupled.
extension Notification.Name {
    /// Toggle recording from the main window Record/Stop button.
    static let toggleRecord = Notification.Name("NotchWhisper.toggleRecord")
    /// The hotkey changed in Settings; re-register the Carbon monitor.
    static let hotkeyChanged = Notification.Name("NotchWhisper.hotkeyChanged")
    /// The active model changed in Settings; reload when next needed.
    static let modelChanged = Notification.Name("NotchWhisper.modelChanged")
    /// Live-dictation toggle changed in Settings; re-route the hotkey/buttons
    /// (and stop a running dictation session if the feature was turned off).
    static let dictationChanged = Notification.Name("NotchWhisper.dictationChanged")
    /// The local LLM model set changed (download/delete/select) — views repaint.
    static let llmModelsChanged = Notification.Name("NotchWhisper.llmModelsChanged")
}
