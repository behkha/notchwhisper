import SwiftUI
import AppKit

// MARK: - Graphite design system components
//
// The shared building blocks for every window. A screen is made of:
//   · a lit graphite canvas (`AuroraBackground`) or real vibrancy
//     (`VisualEffectBackground`) for sidebars and panels,
//   · raised surfaces (`.card()`), and grouped lists (`SettingsGroup`),
//   · crafted controls — `.primaryAction()` / `.secondaryAction()` /
//     `.quietAction()` buttons, `IconButton`, `SegmentedTabs`, `KeyCap`.
// Nothing paints an opaque system color, and the accent is spent only on the
// primary action, the current selection and live state.

// MARK: Canvas

/// The window ground: deep graphite, lit softly from above like a product on
/// a studio sweep, with the faintest breath of the accent at the top edge.
/// Sits behind every content pane.
struct AuroraBackground: View {
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    var body: some View {
        let _ = theme.theme
        ZStack {
            LinearGradient(
                colors: [Tokens.Color.bgRaised, Tokens.Color.bg, Tokens.Color.bgDeep],
                startPoint: .top, endPoint: .bottom
            )
            // Overhead key light — neutral, wide and very low.
            RadialGradient(
                colors: [.white.opacity(0.045), .white.opacity(0.012), .clear],
                center: .init(x: 0.5, y: -0.25), startRadius: 0, endRadius: 720
            )
            // Accent breath — just enough to tie the canvas to the theme.
            RadialGradient(
                colors: [Tokens.Color.accent.opacity(0.07), .clear],
                center: .init(x: 0.85, y: -0.1), startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

/// Real AppKit vibrancy. `.behindWindow` lets the desktop glow through a
/// sidebar exactly like Finder, Mail and Music; the system swaps it for an
/// opaque fill on its own when Reduce Transparency is on.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = emphasized
    }
}

// MARK: Raised surface

/// The one raised surface for the whole app: a quiet graphite panel whose top
/// edge catches the light, continuous corners, and a soft ambient shadow — no
/// outline doing the work a shadow should.
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
            shape.fill(Tokens.Color.card)
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Tokens.Color.edgeLight, Tokens.Color.hairline.opacity(0.45), Tokens.Color.hairline.opacity(0.25)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(elevated ? 0.28 : 0), radius: elevated ? 18 : 0, x: 0, y: elevated ? 10 : 0)
        .shadow(color: .black.opacity(elevated ? 0.20 : 0), radius: elevated ? 1.5 : 0, x: 0, y: 1)
    }
}

extension View {
    /// Wrap content in the standard raised surface.
    func card(radius: CGFloat = Tokens.Radius.lg, padding: CGFloat? = Tokens.Space.x5,
              interactive: Bool = false, elevated: Bool = true) -> some View {
        modifier(CardModifier(radius: radius, padding: padding, interactive: interactive, elevated: elevated))
    }

    /// Hover response for tappable cards: the surface brightens a touch — it
    /// doesn't jump. (Skips the scale entirely under Reduce Motion.)
    func hoverLift(_ hovering: Bool) -> some View {
        scaleEffect(Tokens.A11y.reduceMotion ? 1 : (hovering ? 1.004 : 1))
            .brightness(hovering ? 0.025 : 0)
            .animation(Tokens.Motion.hover, value: hovering)
    }
}

/// A 1 px separator in the shared hairline color.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Tokens.Color.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: Page structure

/// A page's title block: an optional quiet kicker line, the title, an optional
/// subtitle, and a trailing accessory aligned to the title.
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
        HStack(alignment: .headerTitle, spacing: Tokens.Space.x4) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(Tokens.TypeScale.callout.weight(.medium))
                        .foregroundStyle(Tokens.Color.textTert)
                }
                Text(title)
                    .font(Tokens.TypeScale.largeTitle)
                    .foregroundStyle(Tokens.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.headerTitle) { d in d[VerticalAlignment.center] }
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
            Spacer(minLength: Tokens.Space.x4)
            trailing()
                .alignmentGuide(.headerTitle) { d in d[VerticalAlignment.center] }
        }
    }
}

extension VerticalAlignment {
    /// The centre line of a page title, so header accessories sit on it.
    private enum HeaderTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let headerTitle = VerticalAlignment(HeaderTitle.self)
}

/// The label above a group of content — sentence case, secondary, never
/// shouted — with an optional trailing accessory (a count, a link).
struct GroupLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.x2) {
            Text(text)
                .font(Tokens.TypeScale.headline)
                .foregroundStyle(Tokens.Color.textSec)
            Spacer(minLength: Tokens.Space.x2)
            trailing()
        }
        .padding(.horizontal, Tokens.Space.x1)
    }
}

/// A page's scroll container: the reading measure, page margins and the
/// titlebar clearance, applied the same way on every screen.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = Tokens.Layout.contentMaxW
    var spacing: CGFloat = Tokens.Space.x7
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(.horizontal, Tokens.Layout.pagePadH)
            .padding(.top, Tokens.Layout.pagePadTop)
            .padding(.bottom, Tokens.Space.x10)
            .frame(maxWidth: maxWidth + Tokens.Layout.pagePadH * 2, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: Grouped list

/// Settings groups hide their own title when the pane around them already
/// says the same thing (Settings → Microphone holds one "Microphone" group).
private struct SettingsGroupTitleHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsGroupTitleHidden: Bool {
        get { self[SettingsGroupTitleHiddenKey.self] }
        set { self[SettingsGroupTitleHiddenKey.self] = newValue }
    }
}

/// A titled group of rows rendered as one raised surface with inset hairlines
/// between rows — the System Settings grouped list, on graphite.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsGroupTitleHidden) private var titleHidden

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            if let title, !titleHidden {
                GroupLabel(title)
            }
            VStack(spacing: 0) {
                content().variadic { rows in
                    ForEach(rows.indices, id: \.self) { i in
                        rows[i]
                        if i < rows.count - 1 {
                            Hairline().padding(.leading, Tokens.Space.x4)
                        }
                    }
                }
            }
            .card(radius: Tokens.Radius.lg, padding: 0, elevated: false)
            if let footnote {
                Text(footnote)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Space.x1)
                    .padding(.top, 2)
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

/// One row inside a `SettingsGroup`: a title, an optional explanation, and a
/// trailing control. Rows are text-first like System Settings; a glyph only
/// appears when the row carries a status (`tint` set — a warning, an error,
/// a local/remote marker), so the eye goes straight to what needs attention.
struct SettingRow<Trailing: View>: View {
    let icon: String
    var tint: SwiftUI.Color? = nil
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x3) {
            if let tint {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.x4)
            trailing()
                .layoutPriority(1)
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, subtitle == nil ? 11 : Tokens.Space.x3)
        .frame(minHeight: 44)
    }
}

/// A rounded-square glyph plate — the visual anchor for list items.
///  · `.soft`: a quiet graphite plate with a lit top edge; the glyph carries
///    the tint. The default everywhere in content.
///  · `.solid`: the System Settings tile — a saturated fill with a white
///    glyph. Reserved for category navigation.
struct IconTile: View {
    enum Style { case soft, solid }
    let icon: String
    var tint: SwiftUI.Color = Tokens.Color.textSec
    var size: CGFloat = 28
    var style: Style = .soft

    init(_ icon: String, tint: SwiftUI.Color = Tokens.Color.textSec, size: CGFloat = 28, style: Style = .soft) {
        self.icon = icon; self.tint = tint; self.size = size; self.style = style
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            switch style {
            case .soft:
                shape.fill(Tokens.Color.fillQuiet)
                shape.strokeBorder(
                    LinearGradient(colors: [Tokens.Color.edgeLight, Tokens.Color.hairline.opacity(0.3)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(tint)
            case .solid:
                shape.fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.78)],
                                          startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                Image(systemName: icon)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Buttons

/// Hover tracking for button styles — `ButtonStyle` has no hover state of its
/// own, so each style renders its label through this wrapper.
private struct HoverTracking<Content: View>: View {
    @ViewBuilder var content: (_ hovering: Bool) -> Content
    @ViewState private var hovering = false
    var body: some View {
        content(hovering)
            .onHover { inside in
                withAnimation(Tokens.Motion.hover) { hovering = inside }
            }
    }
}

/// Primary CTA: a lit accent capsule with a light-catching top edge.
struct AuroraPrimaryButtonStyle: ButtonStyle {
    var full = false
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(large ? Font.system(size: 14, weight: .semibold) : Tokens.TypeScale.body.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isEnabled ? Tokens.Color.onAccent : Tokens.Color.textTert)
                .padding(.horizontal, large ? Tokens.Space.x6 : Tokens.Space.x4)
                .padding(.vertical, large ? 10 : 6.5)
                .frame(maxWidth: full ? .infinity : nil)
                .background {
                    // Disabled drops to a neutral plate: a dimmed accent reads
                    // as a different colour, not as "unavailable".
                    if isEnabled {
                        Capsule(style: .continuous).fill(Tokens.Color.accentGradient)
                    } else {
                        Capsule(style: .continuous).fill(Tokens.Color.white(0.07))
                    }
                }
                .overlay {
                    Capsule(style: .continuous).strokeBorder(
                        LinearGradient(colors: [.white.opacity(isEnabled ? 0.35 : 0.10), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .brightness(isEnabled ? (configuration.isPressed ? -0.08 : (hovering ? 0.04 : 0)) : 0)
                .shadow(color: Tokens.Color.accent.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.24) : 0),
                        radius: configuration.isPressed ? 3 : 10, y: configuration.isPressed ? 1 : 4)
                .shadow(color: .black.opacity(isEnabled ? 0.25 : 0), radius: 1, y: 1)
                .scaleEffect(Tokens.A11y.reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
                .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
        }
        // An action keeps its full label before neighbouring prose does; under
        // real pressure it truncates rather than wrapping or overflowing.
        .layoutPriority(1)
    }
}

/// Secondary: a graphite capsule with a lit edge. For "Cancel" and the second
/// most important thing on a surface.
struct AuroraSecondaryButtonStyle: ButtonStyle {
    var full = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(Tokens.TypeScale.body.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Tokens.Color.text)
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, 6.5)
                .frame(maxWidth: full ? .infinity : nil)
                .background {
                    Capsule(style: .continuous)
                        .fill(hovering ? Tokens.Color.white(0.11) : Tokens.Color.white(0.075))
                }
                .overlay {
                    Capsule(style: .continuous).strokeBorder(
                        LinearGradient(colors: [Tokens.Color.edgeLight, Tokens.Color.hairline.opacity(0.3)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .scaleEffect(Tokens.A11y.reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
        }
        .layoutPriority(1)
    }
}

/// Tertiary: a text-only action in the accent, for "See all", "Change…",
/// "Edit". A hover wash marks it as clickable without shouting.
struct QuietButtonStyle: ButtonStyle {
    var tint: SwiftUI.Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(Tokens.TypeScale.callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(tint ?? Tokens.Color.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(hovering ? Tokens.Color.hoverFill : .clear)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}

extension View {
    func primaryAction(full: Bool = false, large: Bool = false) -> some View {
        buttonStyle(AuroraPrimaryButtonStyle(full: full, large: large))
    }
    func secondaryAction(full: Bool = false) -> some View { buttonStyle(AuroraSecondaryButtonStyle(full: full)) }
    func quietAction(tint: SwiftUI.Color? = nil) -> some View { buttonStyle(QuietButtonStyle(tint: tint)) }
}

extension Tokens.Color {
    /// A white-alpha fill at an arbitrary strength, for the rare surface that
    /// sits between two named steps.
    static func white(_ opacity: Double) -> SwiftUI.Color { SwiftUI.Color.white.opacity(opacity) }
}

/// A round ghost button for a single glyph (toolbar actions, "more" menus).
struct IconButton: View {
    let systemImage: String
    var help: String? = nil
    var size: CGFloat = 28
    var tint: SwiftUI.Color = Tokens.Color.textSec
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle(tint: tint))
        .help(help ?? "")
        .accessibilityLabel(help ?? systemImage)
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: SwiftUI.Color = Tokens.Color.textSec
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .foregroundStyle(hovering ? Tokens.Color.text : tint)
                .background(Circle().fill(hovering ? Tokens.Color.hoverFill : .clear))
                .contentShape(Circle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
        }
    }
}

// MARK: Segmented tabs

/// An in-page tab switcher: a recessed track with a lit thumb that glides to
/// the selection. For switching between views of one page — never for
/// settings values (those use the system segmented picker).
struct SegmentedTabs<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(Tokens.Motion.select(reduceMotion: Tokens.A11y.reduceMotion)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(Tokens.TypeScale.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Tokens.Color.text : Tokens.Color.textSec)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Tokens.Space.x4)
                        .padding(.vertical, 5)
                        .frame(minWidth: 84)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Tokens.Color.white(0.13))
                                    .overlay(Capsule(style: .continuous).strokeBorder(Tokens.Color.edgeLight, lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Tokens.Color.black(0.28)))
        .overlay(Capsule(style: .continuous).strokeBorder(Tokens.Color.hairline, lineWidth: 1))
    }
}

extension Tokens.Color {
    /// A black-alpha shade, for recessed tracks and wells.
    static func black(_ opacity: Double) -> SwiftUI.Color { SwiftUI.Color.black.opacity(opacity) }
}

// MARK: Key caps

/// A keyboard key, drawn: how every shortcut is shown to the user. Takes the
/// binding's display string ("Right ⌥", "⌘S") as-is.
struct KeyCap: View {
    let text: String
    var dimmed = false
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
        Text(text)
            .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
            .foregroundStyle(dimmed ? Tokens.Color.textTert : Tokens.Color.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1.5 : 3)
            .background {
                ZStack {
                    // The key's skirt: a darker lip showing under the cap.
                    shape.fill(SwiftUI.Color(white: 0.07)).offset(y: 1)
                    shape.fill(LinearGradient(colors: [SwiftUI.Color(white: 0.25), SwiftUI.Color(white: 0.19)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { shape.strokeBorder(Tokens.Color.white(0.09), lineWidth: 0.5) }
            .accessibilityLabel("Shortcut \(text)")
    }
}

// MARK: Status

/// A small status light with a soft bloom; optionally breathing while live.
struct StatusDot: View {
    let color: SwiftUI.Color
    var size: CGFloat = 7
    var pulsing = false
    @ViewState private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.6)
            .overlay {
                if pulsing && !Tokens.A11y.reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1.5)
                        .scaleEffect(phase ? 2.4 : 1)
                        .opacity(phase ? 0 : 0.9)
                        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: phase)
                        .onAppear { phase = true }
                        .onDisappear { phase = false }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Chips & pills

/// Small status/label chip: an optional dot or glyph + text, tinted.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: SwiftUI.Color = Tokens.Color.textSec
    var filled = true

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8.5, weight: .bold))
            } else if filled {
                Circle().fill(tint).frame(width: 5, height: 5)
            }
            Text(text).font(Tokens.TypeScale.micro).lineLimit(1)
        }
        .foregroundStyle(filled ? tint : Tokens.Color.textSec)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(filled ? tint.opacity(0.13) : Tokens.Color.fillQuiet))
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
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Tokens.Color.white(0.07), Tokens.Color.white(0.015)],
                                         center: .top, startRadius: 0, endRadius: 44))
                Circle()
                    .strokeBorder(LinearGradient(colors: [Tokens.Color.edgeLight, .clear],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Tokens.Color.textSec)
            }
            .frame(width: 60, height: 60)
            .padding(.bottom, Tokens.Space.x1)
            Text(title)
                .font(Tokens.TypeScale.title2)
                .foregroundStyle(Tokens.Color.text)
            if let message {
                Text(message)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.textSec)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .primaryAction()
                    .padding(.top, Tokens.Space.x2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Space.x8)
    }
}

// MARK: Menus

extension View {
    /// The house style for a `Menu` that picks a value: the native pop-up
    /// button (graphite plate, primary text, chevron) — never accent-colored
    /// borderless text, which reads as a link.
    func popupMenuStyle() -> some View {
        self.menuStyle(.button)
    }
}

/// The "more actions" control for a row or card: a quiet ellipsis that opens
/// a menu. Neutral, never accent — it's a secondary way in.
struct MoreMenu<Content: View>: View {
    var help: String = "More"
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Tokens.Color.textSec)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Notice banner

/// An inline notice: a tinted glyph, a title, an explanation and an optional
/// action, on a faint wash of the tint. For states that block or qualify the
/// page ("Modes need an AI connection", dictionary conflicts).
struct NoticeBanner<Action: View>: View {
    let icon: String
    var tint: SwiftUI.Color = Tokens.Color.warn
    let title: String
    var message: String? = nil
    @ViewBuilder var action: () -> Action

    init(icon: String, tint: SwiftUI.Color = Tokens.Color.warn, title: String, message: String? = nil,
         @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.icon = icon; self.tint = tint; self.title = title; self.message = message; self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.x3) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Tokens.TypeScale.headline)
                    .foregroundStyle(Tokens.Color.text)
                if let message {
                    Text(message)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.Space.x3)
            action()
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
            .strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

// MARK: Action menus

/// The label for a menu that holds actions ("Export", "Write minutes"): the
/// action, and a small chevron saying a choice follows.
struct MenuLabel: View {
    let title: String
    var systemImage: String? = nil

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Tokens.Color.textTert)
        }
    }
}

extension View {
    /// A `Menu` of actions drawn as a secondary button (pair with `MenuLabel`).
    func secondaryMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(AuroraSecondaryButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
    }
}


/// A filter pill: quiet until a value is chosen, then lit.
struct FilterPillStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous)
                .fill(active ? Tokens.Color.white(0.12) : Tokens.Color.white(0.05)))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(active ? Tokens.Color.hairlineStrong : Tokens.Color.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: Relative dates

extension Date {
    /// "just now", "5 minutes ago", "yesterday" — never "in 0 seconds", which
    /// is what a timestamp at or after the present (a clock that moved back)
    /// reads as otherwise.
    var relativeLabel: String {
        let now = Date()
        if timeIntervalSince(now) > -10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
