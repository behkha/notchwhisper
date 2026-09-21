import AppKit

/// Short system sounds at the edges of a dictation — a tick when the mic
/// opens, a pop when it closes, a low note on failure — so the state is heard
/// without looking at the notch. Off in Settings → Feedback.
enum Feedback {
    enum Kind { case start, stop, error }

    @MainActor static func play(_ kind: Kind) {
        guard Settings.shared.soundFeedback else { return }
        let name: String
        switch kind {
        case .start: name = "Tink"
        case .stop:  name = "Pop"
        case .error: name = "Basso"
        }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.45
        sound.play()
    }
}
