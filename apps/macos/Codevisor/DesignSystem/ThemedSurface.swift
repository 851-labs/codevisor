import SwiftUI

/// Chrome-surface roles for themed "glass". Content surfaces (editor,
/// terminal, diff, composer) stay exact opaque theme colors; these CHROME
/// surfaces render as system material tinted by the theme at partial alpha, so
/// translucency, vibrancy, and desktop tinting survive under a custom theme.
///
/// Each role maps to (a) the palette color that tints the glass, and (b) the
/// system-mode rendering the call site had before theming — which must stay
/// pixel-identical, hence three roles where the themed behavior alone would
/// need two.
enum ThemedSurfaceRole {
    /// Sidebar / inspector panel surfaces. System: regular material.
    case sidebar
    /// Popover content. System: the opaque popover fallback color
    /// (windowBackgroundColor), matching the pre-glass rendering.
    case popover
    /// Sheet chrome (header/footer bands, sheet backdrop). System: nothing —
    /// the native sheet backing shows.
    case sheet
}

/// Renders a chrome surface behind the content:
///   - system theme  → the role's native look (material / fallback / nothing)
///   - custom theme  → material + theme tint at `Theme.chromeTintAlpha`
///   - custom theme + Reduce Transparency → the opaque palette color (the
///     pre-glass themed look), live, via the environment value that tracks
///     NSWorkspace.accessibilityDisplayShouldReduceTransparency.
struct ThemedSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let role: ThemedSurfaceRole
    let shape: S
    /// Rectangular chrome extends under the toolbar exactly like the
    /// ShapeStyle backgrounds it replaces (which ignore safe areas); shaped
    /// chrome (floating drawers) stays in its own bounds.
    let ignoresSafeArea: Bool

    func body(content: Content) -> some View {
        if theme.isSystem {
            switch role {
            case .sidebar:
                content.background { extended(shape.fill(.regularMaterial)) }
            case .popover:
                content.background { extended(shape.fill(theme.popoverBackground)) }
            case .sheet:
                content
            }
        } else if reduceTransparency {
            content.background { extended(shape.fill(opaqueColor)) }
        } else {
            content.background {
                extended(
                    ZStack {
                        shape.fill(.regularMaterial)
                        shape.fill(opaqueColor.opacity(theme.chromeTintAlpha))
                    }
                )
            }
        }
    }

    /// The palette color for this role: the glass tint when translucent, the
    /// whole surface under Reduce Transparency.
    private var opaqueColor: Color {
        switch role {
        case .sidebar:
            theme.sidebarTint ?? .clear
        case .popover, .sheet:
            theme.popoverTint ?? .clear
        }
    }

    @ViewBuilder
    private func extended(_ view: some View) -> some View {
        if ignoresSafeArea {
            view.ignoresSafeArea()
        } else {
            view
        }
    }
}

extension View {
    /// Full-bleed chrome surface (sidebar column, popover body, sheet bands).
    func themedSurface(_ role: ThemedSurfaceRole) -> some View {
        modifier(ThemedSurfaceModifier(role: role, shape: Rectangle(), ignoresSafeArea: true))
    }

    /// Shaped chrome surface (floating drawers). The caller keeps its own
    /// clipShape/shadow, exactly as with the ShapeStyle background this
    /// replaces.
    func themedSurface(_ role: ThemedSurfaceRole, in shape: some Shape) -> some View {
        modifier(ThemedSurfaceModifier(role: role, shape: shape, ignoresSafeArea: false))
    }

    /// Pierre's two-layer card elevation (0 8px 16px /.07 + 0 2px 4px /.05;
    /// CSS blur ≈ 2× SwiftUI radius). Applied only when themed — flat theme
    /// surfaces need the depth cue that native materials carry intrinsically,
    /// while system mode must stay pixel-identical to the unthemed app.
    func themedCardShadow(_ theme: Theme) -> some View {
        shadow(color: .black.opacity(theme.isSystem ? 0 : 0.07), radius: 8, y: 8)
            .shadow(color: .black.opacity(theme.isSystem ? 0 : 0.05), radius: 2, y: 2)
    }
}
