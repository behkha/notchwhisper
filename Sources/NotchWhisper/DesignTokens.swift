import SwiftUI

// MARK: - NotchWhisper Design System — "Graphite"
//
// Every view reads from these tokens; the components in Components.swift are
// the only place they are combined into surfaces. Point at this file to change
// the product's look in one place.

enum Tokens {

    // MARK: Accessibility
    // Motion must respect the user's Reduce Motion setting: when it is on,
    // the notch size morphs become quick fades, the halo stays static, and
    // decorative pulses disappear. Feedback aids comprehension; travel does not.
    enum A11y {
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: Theme
    /// User-selectable accent themes (Settings → Appearance). Each pairs an
    /// accent calibrated for the graphite canvas with a dark, theme-tinted
    /// on-accent color for text and icons on fills. The accent is a signal,
    /// not a decoration: it marks the primary action, the current selection
    /// and anything live — the notch glow and the visualizers included.
    enum Theme: String, CaseIterable, Identifiable {
        case ember, champagne, platinum, ocean, violet, forest, rose, aqua

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ember:     return "Ember"
            case .champagne: return "Champagne"
            case .platinum:  return "Platinum"
            case .ocean:     return "Ocean"
            case .violet:    return "Violet"
            case .forest:    return "Forest"
            case .rose:      return "Rose"
            case .aqua:      return "Aqua"
            }
        }

        var accentRGB: (r: Double, g: Double, b: Double) {
            switch self {
            case .ember:     return (1.00, 0.60, 0.30)
            case .champagne: return (0.91, 0.79, 0.60)
            case .platinum:  return (0.87, 0.88, 0.91)
            case .ocean:     return (0.33, 0.63, 1.00)
            case .violet:    return (0.71, 0.55, 1.00)
            case .forest:    return (0.25, 0.80, 0.53)
            case .rose:      return (1.00, 0.50, 0.65)
            case .aqua:      return (0.25, 0.84, 0.89)
            }
        }

        var accent: SwiftUI.Color {
            SwiftUI.Color(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b)
        }

        /// Dark, theme-tinted text/icon color for accent fills (white fails
        /// contrast on all of these luminous accents).
        var onAccent: SwiftUI.Color {
            switch self {
            case .ember:     return SwiftUI.Color(red: 0.19, green: 0.09, blue: 0.02)
            case .champagne: return SwiftUI.Color(red: 0.17, green: 0.12, blue: 0.05)
            case .platinum:  return SwiftUI.Color(red: 0.07, green: 0.07, blue: 0.08)
            case .ocean:     return SwiftUI.Color(red: 0.02, green: 0.09, blue: 0.21)
            case .violet:    return SwiftUI.Color(red: 0.11, green: 0.05, blue: 0.21)
            case .forest:    return SwiftUI.Color(red: 0.02, green: 0.14, blue: 0.07)
            case .rose:      return SwiftUI.Color(red: 0.21, green: 0.04, blue: 0.10)
            case .aqua:      return SwiftUI.Color(red: 0.00, green: 0.15, blue: 0.16)
            }
        }

        static let defaultsKey = "themeColor"

        /// The active theme, resolved synchronously from UserDefaults for
        /// contexts that need a value without SwiftUI observation (e.g.
        /// Canvas shaders, which redraw every frame anyway).
        static var current: Theme {
            Theme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ember
        }
    }

    // Apply theme to SwiftUI currently requires observing the value. Because
    // `Tokens.Color.accent` reads UserDefaults directly (thread-safe for
    // Canvas), static views have no dependency to observe and won't re-render
    // when the theme changes. `ThemeManager` is the single observable trigger:
    // views that render theme colors hold `@ObservedObject ThemeManager.shared`
    // and read `.theme` in their body, forcing a redraw that re-reads the
    // freshly-updated defaults.
    @MainActor final class ThemeManager: ObservableObject {
        static let shared = ThemeManager()
        @Published var theme: Tokens.Theme {
            didSet { UserDefaults.standard.set(theme.rawValue, forKey: Tokens.Theme.defaultsKey) }
        }
        private init() {
            theme = Tokens.Theme(rawValue: UserDefaults.standard.string(forKey: Tokens.Theme.defaultsKey) ?? "")
                ?? .ember
        }
    }

    // MARK: Color
    //
    // "Graphite" — a dark-only palette built like a Pro app. The windows force
    // `.darkAqua` (AppDelegate) so every surface is designed for one ground,
    // and that ground matches the product's physical anchor: the black notch.
    //
    //  · Canvas: deep graphite, never pure black, lit softly from above.
    //  · Sidebars: real behind-window vibrancy, so the desktop glows through.
    //  · Surfaces: quiet raised panels with a light-catching top edge instead
    //    of heavy outlines.
    //  · Text: Apple's warm white ramp.
    //  · Accent: rationed — primary action, selection, live state. Headers,
    //    labels and decoration stay neutral.
    enum Color {
        // Accent — theme-driven (Settings → Appearance).
        static var accent: SwiftUI.Color { Theme.current.accent }
        static var accentSoft: SwiftUI.Color { accent.opacity(0.14) }
        /// Legible text/icon color on top of `accent` fills (per-theme dark).
        static var onAccent: SwiftUI.Color { Theme.current.onAccent }
        /// The CTA fill: the accent with a whisper of top light, so a filled
        /// control reads as a lit object rather than a flat sticker.
        static var accentGradient: LinearGradient {
            let c = Theme.current.accentRGB
            return LinearGradient(
                colors: [
                    SwiftUI.Color(red: min(1, c.r * 1.06 + 0.02), green: min(1, c.g * 1.06 + 0.02), blue: min(1, c.b * 1.06 + 0.02)),
                    SwiftUI.Color(red: c.r * 0.88, green: c.g * 0.88, blue: c.b * 0.90),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }

        static let record      = SwiftUI.Color(red: 0.98, green: 0.32, blue: 0.35) // #FA525A
        static let recordDark  = SwiftUI.Color(red: 0.80, green: 0.17, blue: 0.21)

        // Canvas — the window ground. `bg` is the flat fallback; `AuroraBackground`
        // paints the lit version on top.
        static let bg          = SwiftUI.Color(red: 0.071, green: 0.071, blue: 0.078) // #121214
        static let bgDeep      = SwiftUI.Color(red: 0.047, green: 0.047, blue: 0.055) // #0C0C0E
        static let bgRaised    = SwiftUI.Color(red: 0.094, green: 0.094, blue: 0.106) // #18181B

        // Raised surfaces (white-alpha over the graphite canvas).
        static let surface     = SwiftUI.Color.white.opacity(0.045)
        static let surface2    = SwiftUI.Color.white.opacity(0.028)
        static let elevated    = SwiftUI.Color.white.opacity(0.075)
        static let card        = SwiftUI.Color.white.opacity(0.042)
        static let cardHover   = SwiftUI.Color.white.opacity(0.07)

        // Text — Apple's warm white ramp.
        static let text        = SwiftUI.Color(red: 0.961, green: 0.961, blue: 0.969) // #F5F5F7
        static let textSec     = SwiftUI.Color.white.opacity(0.62)
        static let textTert    = SwiftUI.Color.white.opacity(0.40)
        static let textQuat    = SwiftUI.Color.white.opacity(0.24)
        static let textOnAccent = SwiftUI.Color.white

        // Semantic
        static let success     = SwiftUI.Color(red: 0.24, green: 0.82, blue: 0.50) // #3DD180
        static let warn        = SwiftUI.Color(red: 1.00, green: 0.78, blue: 0.30) // #FFC74D
        static let danger      = SwiftUI.Color(red: 1.00, green: 0.39, blue: 0.38) // #FF6361

        // Lines / fills / hairlines
        static let separator   = SwiftUI.Color.white.opacity(0.07)
        static let hairline    = SwiftUI.Color.white.opacity(0.075)
        static let hairlineStrong = SwiftUI.Color.white.opacity(0.13)
        /// The light-catching top edge of a raised surface.
        static let edgeLight   = SwiftUI.Color.white.opacity(0.11)
        static let fillQuiet   = SwiftUI.Color.white.opacity(0.065)
        static let fillQuieter = SwiftUI.Color.white.opacity(0.035)
        /// Hover wash for rows and ghost controls.
        static let hoverFill   = SwiftUI.Color.white.opacity(0.055)
        /// The neutral selection fill (sidebars, segmented thumbs).
        static let selectionFill = SwiftUI.Color.white.opacity(0.10)
        static let notchFill   = SwiftUI.Color.black.opacity(0.82)
        static let notchStroke = SwiftUI.Color.white.opacity(0.16)

        // Notch waveform — one subtle vertical gradient across all bars:
        // white → pale cyan, plus a barely-there glow. No rainbow.
        static let waveTop     = SwiftUI.Color.white.opacity(0.95)
        static let waveBottom  = SwiftUI.Color(red: 0.64, green: 0.89, blue: 0.98).opacity(0.72)
        static let waveGlow    = SwiftUI.Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.20)

        // Voice-reactive halo — the notch's ambient glow while recording.
        // Quiet = the theme's accent color (the "listening" tint); loud = a
        // hot red (matching the record dot) for every theme. Interpolated by
        // Tokens.glow(for:) from the smoothed mic energy.
        static var glowQuietRGB: (r: Double, g: Double, b: Double) { Theme.current.accentRGB }
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
    // SF Pro at macOS sizes: 13 pt body, a confident but quiet title ramp.
    // SF Pro switches to its Display optical size (and tighter tracking) on
    // its own above 20 pt, so titles need no manual kerning. Numerals that
    // report a value use `stat` — light, large, tabular.
    enum TypeScale {
        static let display    = Font.system(size: 30, weight: .bold)
        static let largeTitle = Font.system(size: 26, weight: .bold)
        static let title1     = Font.system(size: 20, weight: .semibold)
        static let title2     = Font.system(size: 16, weight: .semibold)
        static let title3     = Font.system(size: 14, weight: .semibold)
        static let headline   = Font.system(size: 13, weight: .semibold)
        static let body       = Font.system(size: 13, weight: .regular)
        static let bodyMono   = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let callout    = Font.system(size: 12, weight: .regular)
        static let caption    = Font.system(size: 11, weight: .regular)
        static let captionSB  = Font.system(size: 11, weight: .semibold)
        /// Group and sidebar section labels (sentence case, never shouted).
        static let eyebrow    = Font.system(size: 11, weight: .semibold)
        /// A reported value: light, large, tabular.
        static let stat       = Font.system(size: 28, weight: .light).monospacedDigit()
        // Notch content type — fixed (the notch band height is hardware), so
        // it never follows the window scale.
        static let notchLabel = Font.system(size: 11, weight: .medium, design: .rounded)
        static let notchCallout = Font.system(size: 13, weight: .regular)
        static let notchMicro = Font.system(size: 11, weight: .medium)
        /// Window-UI micro label (chips, badges).
        static let micro = Font.system(size: 11, weight: .medium)
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
        static let x7: CGFloat = 28
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
        static let x12: CGFloat = 48
    }

    // MARK: Corner radius
    // Continuous corners everywhere; nested shapes step down so corners stay
    // concentric (outer radius − padding ≈ inner radius).
    enum Radius {
        static let xs: CGFloat = 5
        static let sm: CGFloat = 7
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 26
        static let pill: CGFloat = 999
    }

    // MARK: Elevation (ambient shadows on the graphite canvas)
    enum Elevation {
        static func card(_ view: some View) -> some View {
            view.shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
                .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
        }
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
        static let panel = (color: SwiftUI.Color.black.opacity(0.28),
                           radius: CGFloat(18), x: CGFloat(0), y: CGFloat(8))
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
        /// Selection moving between siblings (sidebars, segmented thumbs).
        static let select  = Animation.spring(response: 0.34, dampingFraction: 0.86)
        static let openMorph  = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let closeMorph = Animation.spring(response: 0.30, dampingFraction: 0.88)
        // Notch pill dot → capsule morph (Dynamic-Island-ish).
        static let islandMorph = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let meter   = Animation.spring(response: 0.12, dampingFraction: 0.6)

        // Reduce Motion variants: same completions, no travel/spring. Cross-
        // fades stay (they aid comprehension); positional morphs collapse to
        // a short fade. Call sites use `Motion.x(reduceMotion:)`.
        static func ease(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.15) : Self.ease }
        static func quick(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : Self.quick }
        static func select(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : Self.select }
        static func openMorph(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.15) : Self.openMorph }
        static func closeMorph(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : Self.closeMorph }
    }

    // MARK: Layout constants
    enum Layout {
        static let sidebarW: CGFloat = 224
        /// Clear space above sidebar content for the traffic lights.
        static let titlebarInset: CGFloat = 52
        /// The reading measure for a page's content column.
        static let contentMaxW: CGFloat = 860
        /// A wider measure for catalogue pages (Models) with grids and tables.
        static let wideContentMaxW: CGFloat = 980
        static let pagePadH: CGFloat = 40
        static let pagePadTop: CGFloat = 44
        static let minWinW: CGFloat = 900
        static let minWinH: CGFloat = 620
        static let maxWinW: CGFloat = 1440
        static let maxWinH: CGFloat = 1000
        static let meterW: CGFloat = 220
        static let rowH: CGFloat = 17
    }
}

// MARK: - Reusable modifiers (token-bound)

/// A subtle pressed scale using Motion.quick, so any tappable surface gives
/// immediate feedback without one-off scales in components. Under Reduce
/// Motion the press is signaled by opacity instead of travel.
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(Tokens.A11y.reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .opacity(configuration.isPressed && Tokens.A11y.reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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

    /// Bounces an SF Symbol when `value` changes — confirmation feedback
    /// (copy succeeded, recording started). Under Reduce Motion the bounce
    /// is skipped: the icon/color swap alone still signals the change.
    @ViewBuilder
    func symbolFeedback(value: some Equatable) -> some View {
        if Tokens.A11y.reduceMotion {
            self
        } else {
            self.symbolEffect(.bounce, value: value)
        }
    }
}
