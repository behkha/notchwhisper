import SwiftUI

// MARK: - Glass surface helpers
//
// Thin compatibility shims that map the older `.glassSurface()` / `.glassRow()`
// / `.glassButton()` call sites onto the Aurora design system in
// `Components.swift`. Keeping the names means the Models view (the last heavy
// user) didn't need a line-by-line rewrite.

extension View {
    /// A raised glass card (the standard content surface).
    func glassSurface(cornerRadius: CGFloat = Tokens.Radius.lg,
                      interactive: Bool = false) -> some View {
        card(radius: cornerRadius, padding: nil, interactive: interactive, elevated: true)
    }

    /// A lighter, flat glass row (list rows, search bars, chips).
    func glassRow(cornerRadius: CGFloat = Tokens.Radius.md) -> some View {
        card(radius: cornerRadius, padding: nil, elevated: false)
    }

    /// Bridges the old button helper to the Aurora button styles.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if prominent {
            self.buttonStyle(AuroraPrimaryButtonStyle())
        } else {
            self.buttonStyle(AuroraSecondaryButtonStyle())
        }
    }

    /// Dark-tinted Liquid Glass for the notch island: on macOS 26 the glass
    /// adds the system's refraction/depth over the black silhouette; on older
    /// releases it's a no-op (the silhouette already reads correctly).
    @ViewBuilder
    func glassIsland<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Glass.regular.tint(Color.black.opacity(0.5)), in: shape)
        } else {
            self
        }
    }
}

/// A leading-aligned vertical stack (kept for source compatibility; the Aurora
/// layouts use plain VStacks).
struct GlassStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity)
    }
}
