import SwiftUI

// MARK: - Aurora design system components
//
// The shared building blocks for the ground-up redesign. Every window surface
// is one of: the `AuroraBackground` canvas, a `.card()` glass panel, or a
// `SettingsGroup` of `SettingRow`s. Buttons use `.primaryAction()` /
// `.secondaryAction()`. Nothing paints an opaque system color.

// MARK: Canvas

/// The window ground: a near-black vertical gradient with a soft accent "aurora"
/// bloom at the top and a faint vignette. Sits behind every screen.
struct AuroraBackground: View {
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    var body: some View {
        let _ = theme.theme
        let a = Tokens.Color.accent
        ZStack {
            LinearGradient(
                colors: [Tokens.Color.bgRaised, Tokens.Color.bg, Tokens.Color.bgDeep],
                startPoint: .top, endPoint: .bottom
            )
            // Accent aurora, top-center.
            RadialGradient(
                colors: [a.opacity(0.20), a.opacity(0.05), .clear],
                center: .init(x: 0.5, y: -0.15), startRadius: 0, endRadius: 520
            )
            .blendMode(.plusLighter)
            // Cool counter-glow, bottom-right, for depth.
            RadialGradient(
                colors: [a.opacity(0.08), .clear],
                center: .init(x: 1.05, y: 1.1), startRadius: 0, endRadius: 460
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: Glass card

/// The one card surface for the whole app: a frosted glass fill, a hairline
/// stroke with a brighter top edge (the "liquid glass" light-catch), continuous
/// corners and an ambient shadow.
struct CardModifier: ViewModifier {
    var radius: CGFloat = Tokens.Radius.lg
    var padding: CGFloat? = Tokens.Space.x5
    var interactive = false
    var elevated = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Group {
            if let padding { content.padding(padding) } else { content }
        }
        .background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Tokens.Color.card))
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Tokens.Color.hairlineStrong, Tokens.Color.hairline.opacity(0.3)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(elevated ? 0.35 : 0), radius: elevated ? 20 : 0, x: 0, y: elevated ? 10 : 0)
        .shadow(color: .black.opacity(elevated ? 0.16 : 0), radius: elevated ? 2 : 0, x: 0, y: 1)
    }
}

extension View {
    /// Wrap content in the standard glass card.
    func card(radius: CGFloat = Tokens.Radius.lg, padding: CGFloat? = Tokens.Space.x5,
              interactive: Bool = false, elevated: Bool = true) -> some View {
        modifier(CardModifier(radius: radius, padding: padding, interactive: interactive, elevated: elevated))
    }

    /// Hover lift for tappable cards (skipped under Reduce Motion).
    func hoverLift(_ hovering: Bool) -> some View {
        scaleEffect(Tokens.A11y.reduceMotion ? 1 : (hovering ? 1.012 : 1))
            .brightness(hovering ? 0.04 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

// MARK: Section header

/// Eyebrow + big title, with an optional trailing accessory. Used at the top of
/// every content section.
struct SectionHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.eyebrow = eyebrow
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Tokens.TypeScale.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.Color.accent)
                }
                Text(title)
                    .font(Tokens.TypeScale.largeTitle)
                    .foregroundStyle(Tokens.Color.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                }
            }
            Spacer(minLength: Tokens.Space.x4)
            trailing()
        }
    }
}

// MARK: Settings group + row

/// A titled group of setting rows rendered as one card with internal dividers —
/// the macOS/Raycast "grouped list" look, rebuilt on glass.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            if let title {
                Text(title.uppercased())
                    .font(Tokens.TypeScale.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Tokens.Color.textTert)
                    .padding(.leading, Tokens.Space.x2)
            }
            VStack(spacing: 0) {
                content().variadic { rows in
                    ForEach(rows.indices, id: \.self) { i in
                        rows[i]
                        if i < rows.count - 1 {
                            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .card(padding: 0)
            if let footnote {
                Text(footnote)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Tokens.Space.x2)
            }
        }
    }
}

/// `content.variadic { children in … }` — access a ViewBuilder's children as a
/// collection (via the long-stable `_VariadicView` bridge) so a group can put
/// dividers between arbitrary rows without the caller threading indices.
extension View {
    func variadic<R: View>(@ViewBuilder _ transform: @escaping (_VariadicView.Children) -> R) -> some View {
        _VariadicView.Tree(_VariadicRoot(transform)) { self }
    }
}

private struct _VariadicRoot<R: View>: _VariadicView.MultiViewRoot {
    let transform: (_VariadicView.Children) -> R
    init(_ transform: @escaping (_VariadicView.Children) -> R) { self.transform = transform }
    func body(children: _VariadicView.Children) -> some View { transform(children) }
}

/// One row inside a `SettingsGroup`: an icon tile, a title + optional subtitle,
/// and a trailing control (toggle, picker, button, chevron…).
struct SettingRow<Trailing: View>: View {
    let icon: String
    var tint: SwiftUI.Color = Tokens.Color.accent
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: Tokens.Space.x3) {
            IconTile(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.TypeScale.body.weight(.medium))
                    .foregroundStyle(Tokens.Color.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.x3)
            trailing()
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3)
    }
}

/// A rounded-square icon chip with a tinted glyph — the visual anchor for rows.
struct IconTile: View {
    let icon: String
    var tint: SwiftUI.Color = Tokens.Color.accent
    var size: CGFloat = 28
    init(_ icon: String, tint: SwiftUI.Color = Tokens.Color.accent, size: CGFloat = 28) {
        self.icon = icon; self.tint = tint; self.size = size
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}

// MARK: Buttons

/// Primary CTA: the accent gradient, on-accent label, pill shape, press spring.
struct AuroraPrimaryButtonStyle: ButtonStyle {
    var full = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.TypeScale.body.weight(.semibold))
            .foregroundStyle(Tokens.Color.onAccent)
            .padding(.horizontal, Tokens.Space.x5)
            .padding(.vertical, Tokens.Space.x3)
            .frame(maxWidth: full ? .infinity : nil)
            .background(
                Capsule(style: .continuous).fill(Tokens.Color.accentGradient)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Tokens.Color.accent.opacity(configuration.isPressed ? 0.1 : 0.35),
                    radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 1 : 5)
            .scaleEffect(Tokens.A11y.reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Secondary: glass fill, hairline, subtle. For "Cancel" / low-emphasis actions.
struct AuroraSecondaryButtonStyle: ButtonStyle {
    var full = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.TypeScale.body.weight(.medium))
            .foregroundStyle(Tokens.Color.text)
            .padding(.horizontal, Tokens.Space.x4)
            .padding(.vertical, Tokens.Space.x3)
            .frame(maxWidth: full ? .infinity : nil)
            .background(Capsule(style: .continuous).fill(Tokens.Color.fillQuiet))
            .overlay(Capsule(style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(Tokens.A11y.reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension View {
    func primaryAction(full: Bool = false) -> some View { buttonStyle(AuroraPrimaryButtonStyle(full: full)) }
    func secondaryAction(full: Bool = false) -> some View { buttonStyle(AuroraSecondaryButtonStyle(full: full)) }
}

// MARK: Chips & pills

/// Small status/label chip: dot + text, tinted.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: SwiftUI.Color = Tokens.Color.textSec
    var filled = true

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text).font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(filled ? tint : Tokens.Color.textSec)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, 4)
        .background(Capsule().fill(filled ? tint.opacity(0.14) : Tokens.Color.fillQuiet))
        .overlay(Capsule().strokeBorder(filled ? tint.opacity(0.0) : Tokens.Color.hairline, lineWidth: 1))
    }
}

// MARK: Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Tokens.Space.x3) {
            IconTile(icon, size: 56)
            Text(title)
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
            if let message {
                Text(message)
                    .font(Tokens.TypeScale.callout)
                    .foregroundStyle(Tokens.Color.textSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .primaryAction()
                    .padding(.top, Tokens.Space.x1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Space.x8)
    }
}
