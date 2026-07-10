import Foundation

/// Resolves a theme's workbench `colors` map: applies the standard fallback
/// chains and a few universal repairs so every consumer reads one resolved set
/// of keys instead of re-deriving the chains. Ported from
/// `.repos/pierre/packages/theming/src/modules/normalizeThemeColors.ts`.
///
/// What it fills (mechanical fallback, no opinion):
///   - surfaces: editor/sideBar background+foreground, input.background,
///     sideBarSectionHeader.foreground, list.activeSelectionForeground — via
///     the editor→base and sideBar→editor→base precedence.
///   - git status: gitDecoration.{added,modified,deleted}ResourceForeground via
///     the gitDecoration → terminal.ansi* → editorGutter.* chain.
///   - focus ring: list.focusOutline set to the first NON-transparent of
///     [list.focusOutline, focusBorder].
///
/// What it repairs:
///   - drops list.hoverBackground when it exactly equals the sidebar surface
///     or would land on top of the row text (hoverWouldEraseText).
///
/// The function is pure and idempotent: normalize(normalize(t)) == normalize(t).
public enum ThemeNormalizer {
    public static func normalize(_ theme: VSCodeTheme) -> VSCodeTheme {
        let originalColors = theme.colors ?? [:]
        var colors = originalColors

        // Surface precedence: the editor falls back to the base theme bg/fg,
        // and the sidebar falls back to the editor. An explicit value is always
        // honored and the chain never invents a color.
        let editorBackground = originalColors["editor.background"] ?? theme.bg
        let editorForeground = originalColors["editor.foreground"] ?? theme.fg
        let sidebarBackground = originalColors["sideBar.background"] ?? editorBackground
        let sidebarForeground = originalColors["sideBar.foreground"] ?? editorForeground

        fill(&colors, "editor.background", editorBackground)
        fill(&colors, "editor.foreground", editorForeground)
        fill(&colors, "sideBar.background", sidebarBackground)
        fill(&colors, "sideBar.foreground", sidebarForeground)
        fill(&colors, "input.background", originalColors["input.background"] ?? sidebarBackground)
        fill(
            &colors,
            "sideBarSectionHeader.foreground",
            originalColors["sideBarSectionHeader.foreground"] ?? sidebarForeground
        )
        fill(
            &colors,
            "list.activeSelectionForeground",
            originalColors["list.activeSelectionForeground"] ?? sidebarForeground
        )

        // Git status foreground chains: the dedicated gitDecoration key, then
        // the terminal ANSI color, then the editor gutter background (which
        // catches gutter-only themes like vesper).
        fill(
            &colors,
            "gitDecoration.addedResourceForeground",
            firstColor(
                originalColors["gitDecoration.addedResourceForeground"],
                originalColors["terminal.ansiGreen"],
                originalColors["editorGutter.addedBackground"]
            )
        )
        fill(
            &colors,
            "gitDecoration.modifiedResourceForeground",
            firstColor(
                originalColors["gitDecoration.modifiedResourceForeground"],
                originalColors["terminal.ansiBlue"],
                originalColors["editorGutter.modifiedBackground"]
            )
        )
        fill(
            &colors,
            "gitDecoration.deletedResourceForeground",
            firstColor(
                originalColors["gitDecoration.deletedResourceForeground"],
                originalColors["terminal.ansiRed"],
                originalColors["editorGutter.deletedBackground"]
            )
        )

        // Focus ring: first non-transparent of [list.focusOutline, focusBorder].
        // A transparent outline is rejected so the resolved key is always a
        // visible color; if neither candidate is visible the key ends absent.
        let focusOutline = originalColors["list.focusOutline"]
        let focusBorder = originalColors["focusBorder"]
        let focusRing =
            (ColorMath.isFullyTransparent(focusOutline) ? nil : focusOutline)
            ?? (ColorMath.isFullyTransparent(focusBorder) ? nil : focusBorder)
        if let focusRing {
            colors["list.focusOutline"] = focusRing
        } else {
            colors.removeValue(forKey: "list.focusOutline")
        }

        // Hover repair: a hover background that exactly matches the surface, or
        // that sits closer to the text color than the surface (so it would
        // erase the row text), is unusable for any consumer — drop it and let
        // the consumer apply its own hover default.
        if let hover = originalColors["list.hoverBackground"],
            matchesSurface(hover, sidebarBackground)
                || ColorMath.hoverWouldEraseText(
                    hover: hover, bg: sidebarBackground, fg: sidebarForeground)
        {
            colors.removeValue(forKey: "list.hoverBackground")
        }

        var result = theme
        result.colors = colors
        return result
    }

    // Writes `value` to `key` only when it is a real color, so an absent source
    // key stays absent rather than being coerced to an empty string.
    private static func fill(_ colors: inout [String: String], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { colors[key] = value }
    }

    // Returns the first non-empty color among the candidates, in priority
    // order, so a blank workbench key falls through to the next tier.
    private static func firstColor(_ candidates: String?...) -> String? {
        candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    // Case-insensitive exact-string surface match (NOT a luminance compare),
    // matching the equality the hover repair has always used.
    private static func matchesSurface(_ color: String, _ surface: String?) -> Bool {
        guard let surface else { return false }
        return color.lowercased() == surface.lowercased()
    }
}
