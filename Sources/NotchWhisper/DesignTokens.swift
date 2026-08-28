import SwiftUI

// MARK: - NotchWhisper Design System
//
// Minimal, Apple-flavored tokens. Every view reads from these — there are
// intentionally no one-off magic values in the components. Point at this file
// to change the product's look in one place.

enum Tokens {

    // MARK: Color
    // A calm, neutral surface with a single accent (the recording red) and
    // semantic tints. Dark-first because the app lives in the notch + a
    // transcript list, but light is supported via the system appearance.
    enum Color {
        // Accent — used sparingly: the record action, active states.
        static let accent      = SwiftUI.Color.accentColor
        static let record      = SwiftUI.Color(red: 0.93, green: 0.27, blue: 0.27) // #ED4545
        static let recordDark  = SwiftUI.Color(red: 0.80, green: 0.18, blue: 0.18)

        // Surfaces (dark)
        static let bg          = SwiftUI.Color(NSColor.windowBackgroundColor)
        static let surface     = SwiftUI.Color(NSColor.controlBackgroundColor)
        static let surface2    = SwiftUI.Color(NSColor.underPageBackgroundColor)
        static let elevated    = SwiftUI.Color(NSColor.textBackgroundColor)

        // Text
        static let text        = SwiftUI.Color.primary
        static let textSec     = SwiftUI.Color.secondary
        static let textTert    = SwiftUI.Color(NSColor.tertiaryLabelColor)
        static let textOnAccent = SwiftUI.Color.white

        // Semantic
        static let success     = SwiftUI.Color(red: 0.20, green: 0.78, blue: 0.50) // #33C780
        static let warn        = SwiftUI.Color(red: 0.96, green: 0.65, blue: 0.14) // #F5A623
        static let danger      = SwiftUI.Color(red: 0.90, green: 0.29, blue: 0.30) // #E64A4D

        // Lines / fills
        static let separator   = SwiftUI.Color(NSColor.separatorColor)
        static let fillQuiet   = SwiftUI.Color(NSColor.quaternaryLabelColor).opacity(0.18)
        static let notchFill   = SwiftUI.Color.black.opacity(0.82)
        static let notchStroke = SwiftUI.Color.white.opacity(0.16)

        // Notch waveform — one subtle vertical gradient across all bars:
        // white → pale cyan, plus a barely-there glow. No rainbow.
        static let waveTop     = SwiftUI.Color.white.opacity(0.95)
        static let waveBottom  = SwiftUI.Color(red: 0.64, green: 0.89, blue: 0.98).opacity(0.72)
        static let waveGlow    = SwiftUI.Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.20)

        // Voice-reactive halo — the notch's ambient glow while recording.
        // Quiet = a golden amber (the "listening" ember); loud = a hot red
        // (matching the record dot). The ramp is deliberately WIDE so the
        // heat-up is unmistakable. Interpolated by Tokens.glow(for:) from the
        // smoothed mic energy.
        static let glowQuietRGB: (r: Double, g: Double, b: Double) = (1.00, 0.70, 0.32) // golden amber
        static let glowLoudRGB:  (r: Double, g: Double, b: Double) = (1.00, 0.15, 0.15) // hot red
        static var glowQuiet: SwiftUI.Color {
            SwiftUI.Color(red: glowQuietRGB.r, green: glowQuietRGB.g, blue: glowQuietRGB.b)
        }
        static var glowLoud: SwiftUI.Color {
            SwiftUI.Color(red: glowLoudRGB.r, green: glowLoudRGB.g, blue: glowLoudRGB.b)
        }
    }

    /// RGB interpolation of the voice-reactive glow for a smoothed energy
    /// 0…1. Quiet speech stays amber; loud speech heats up toward coral.
    static func glowRGB(for energy: CGFloat) -> (r: Double, g: Double, b: Double) {
        let e = Double(min(1, max(0, energy)))
        let q = Color.glowQuietRGB
        let l = Color.glowLoudRGB
        return (q.r + (l.r - q.r) * e,
                q.g + (l.g - q.g) * e,
                q.b + (l.b - q.b) * e)
    }

    /// Color form of glowRGB(for:).
    static func glow(for energy: CGFloat) -> SwiftUI.Color {
        let c = glowRGB(for: energy)
        return SwiftUI.Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: Typography
    // System fonts only. A small, disciplined scale.
    enum TypeScale {
        static let largeTitle = Font.system(size: 26, weight: .bold, design: .default)
        static let title1     = Font.system(size: 20, weight: .semibold, design: .default)
        static let title2     = Font.system(size: 16, weight: .semibold, design: .default)
        static let headline   = Font.system(size: 14, weight: .semibold, design: .default)
        static let body       = Font.system(size: 14, weight: .regular, design: .default)
        static let bodyMono   = Font.system(size: 13, weight: .regular, design: .monospaced)
        static let callout    = Font.system(size: 13, weight: .regular, design: .default)
        static let caption    = Font.system(size: 12, weight: .regular, design: .default)
        static let captionSB  = Font.system(size: 12, weight: .semibold, design: .default)
        static let micro      = Font.system(size: 11, weight: .medium, design: .rounded)
    }

    // MARK: Spacing
    // 4pt base unit.
    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
    }

    // MARK: Corner radius
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Border
    enum Border {
        static let hair: CGFloat = 0.5
        static let thin: CGFloat = 1
    }

    // MARK: Shadow
    enum Shadow {
        // Notch pill — soft, no hard drop.
        static let notch = (color: SwiftUI.Color.black.opacity(0.35),
                            radius: CGFloat(8), x: CGFloat(0), y: CGFloat(2))
        // Floating panels (settings, popovers).
        static let panel = (color: SwiftUI.Color.black.opacity(0.22),
                           radius: CGFloat(16), x: CGFloat(0), y: CGFloat(6))
        // Pressed / lifted elements.
        static let lift  = (color: SwiftUI.Color.black.opacity(0.30),
                           radius: CGFloat(10), x: CGFloat(0), y: CGFloat(3))
    }

    // MARK: Motion
    // Emil Kowalski's strong ease-out (cubic-bezier 0.23, 1, 0.32, 1) plus a
    // few tuned springs, reused everywhere so transitions read as one product.
    enum Motion {
        static let ease    = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
        static let quick   = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
        static let hover   = Animation.easeOut(duration: 0.12)
        static let openMorph  = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let closeMorph = Animation.spring(response: 0.30, dampingFraction: 0.88)
        // Notch pill dot → capsule morph (Dynamic-Island-ish).
        static let islandMorph = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let meter   = Animation.spring(response: 0.12, dampingFraction: 0.6)
    }

    // MARK: Layout constants
    enum Layout {
        static let sidebarW: CGFloat = 240
        static let minWinW: CGFloat = 880
        static let minWinH: CGFloat = 600
        static let maxWinW: CGFloat = 1280
        static let maxWinH: CGFloat = 940
        static let meterW: CGFloat = 220
        static let rowH: CGFloat = 17
    }
}

// MARK: - Reusable modifiers (token-bound)

/// A subtle pressed scale using Motion.quick, so any tappable surface gives
/// immediate feedback without one-off scales in components.
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

extension View {
    /// Applies the standard floating-panel shadow.
    func panelShadow() -> some View {
        self.shadow(
            color: Tokens.Shadow.panel.color,
            radius: Tokens.Shadow.panel.radius,
            x: Tokens.Shadow.panel.x,
            y: Tokens.Shadow.panel.y
        )
    }
}
