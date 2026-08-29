import SwiftUI

// MARK: - Liquid Glass helpers (macOS 26 native design system)
//
// These small, token-bound wrappers are the single place the app touches the
// macOS 26 Liquid Glass APIs. Every call is guarded by `#available(macOS 26, *)`
// so the app still compiles and runs on macOS 14/15 — on those older releases
// it automatically falls back to the long-standing native vibrancy Material
// (which already reads as frosted glass), and on macOS 26 it renders true
// system Liquid Glass with refraction and depth.
//
// Using these instead of ad-hoc backgrounds is what makes the whole UI feel
// like one coherent, native macOS Tahoe surface.

/// A vertical stack that provides a Liquid Glass *context* on macOS 26 — i.e.
/// it becomes a `GlassEffectContainer` so any descendant using
/// `.glassSurface()` renders as real system glass — and a plain `VStack`
/// everywhere else. Layout is identical on both paths (leading, full-width),
/// so call sites can drop it in where they previously used `VStack`.
struct GlassStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { stack }
        } else {
            stack
        }
    }
}

extension View {

    /// A glass "card" surface with continuous corners.
    ///   · macOS 26 → `.glassEffect()` (true Liquid Glass).
    ///   · older    → a frosted `Material` panel (native vibrancy).
    ///
    /// `interactive: true` opts the surface into the system's pointer
    /// response (hover/press highlights) on macOS 26 — right for anything
    /// tappable, wrong for static cards.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Tokens.Radius.lg,
                      interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if interactive {
                self.glassEffect(.regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self.background(.bar, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A clear/translucent hoverable surface that becomes glass on macOS 26.
    /// Used for list rows and bars where a full card would be too heavy.
    @ViewBuilder
    func glassRow(cornerRadius: CGFloat = Tokens.Radius.md) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(Material.bar, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A native glass button on macOS 26 (`.glass` / `.glassProminent`); native
    /// `borderedProminent` elsewhere. Pair with `.tint(...)` to color the glass.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Dark-tinted Liquid Glass for the notch island: on macOS 26 the glass
    /// adds the system's refraction/depth over the black silhouette while a
    /// moderate dark tint keeps white content legible on any desktop. On older
    /// releases this is a no-op (the black silhouette already reads correctly).
    @ViewBuilder
    func glassIsland<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Glass.regular.tint(Color.black.opacity(0.45)), in: shape)
        } else {
            self
        }
    }
}

// MARK: - Glass window background (AppKit vibrancy)
//
// A reusable NSVisualEffectView-hosted window. The window itself becomes a
// frosted, refractive glass surface on macOS 26 and a clean vibrancy panel on
// earlier macOS — the foundation the SwiftUI glass sits on top of.

extension NSWindow {
    /// Configures this window as a transparent, vibrant glass surface:
    /// a clear titlebar (so the toolbar is glass) over an `NSVisualEffectView`
    /// whose material refracts whatever is behind the window.
    func applyGlassAppearance() {
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        isOpaque = false
        backgroundColor = .clear
        // Within-window blending composites the material against the (clear)
        // window background, which lets the desktop show through frosted.
        if let effectView = contentView as? NSVisualEffectView {
            effectView.material = .underWindowBackground
            effectView.blendingMode = .withinWindow
            effectView.state = .active
            effectView.wantsLayer = true
        }
    }
}
