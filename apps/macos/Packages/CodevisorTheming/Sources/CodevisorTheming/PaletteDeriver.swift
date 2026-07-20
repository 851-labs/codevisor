import Foundation

/// The 16-slot ANSI palette plus core surface colors a terminal needs, derived
/// from a theme's `terminal.*` keys with editor fallbacks. Slots the theme
/// doesn't define stay nil so the terminal keeps its own defaults.
public struct TerminalPalette: Equatable, Sendable {
    public let background: RGBA
    public let foreground: RGBA
    public let cursorColor: RGBA?
    public let selectionBackground: RGBA?
    public let selectionForeground: RGBA?
    /// ANSI colors 0–15 in standard order (black…white, brightBlack…brightWhite).
    public let ansi: [RGBA?]
}

/// The opinionated app palette derived from a VSCode/Shiki theme. Authored
/// theme keys win wherever the theme provides a usable one (accent, row
/// hover/selection, elevated widget/menu surfaces, status tints — each behind
/// a legibility guard); derivation (fg-mix surfaces, derived muted text,
/// luminance-picked status constants) is the fallback, not the rule. Ported
/// from the web app's `deriveChromeTokens.ts` + `codevisorChromeMapping.ts`
/// (themselves adapted from pierre's diffshub app). All colors are concrete
/// sRGB values; only `border` and the diff backgrounds carry alpha.
public struct DerivedPalette: Equatable, Sendable {
    public let isDark: Bool

    // Surfaces
    public let windowBackground: RGBA
    public let sidebarBackground: RGBA
    public let cardBackground: RGBA
    public let cardHoverBackground: RGBA
    public let cardBorder: RGBA
    public let popoverBackground: RGBA
    public let popoverBorder: RGBA
    public let composerBackground: RGBA
    public let bubbleBackground: RGBA
    /// The pane-group header (tab strip) surface: the pane content color
    /// nudged toward the foreground, so a selected tab filled with the pane
    /// surface reads as a cutout opening into the pane below.
    public let paneHeaderBackground: RGBA

    // Text hierarchy
    public let textPrimary: RGBA
    public let textSecondary: RGBA
    public let textTertiary: RGBA

    // Interaction
    public let rowHoverBackground: RGBA
    public let rowSelectedBackground: RGBA
    public let accent: RGBA
    public let focusRing: RGBA

    // Borders
    public let border: RGBA
    public let borderOpaque: RGBA
    public let separator: RGBA

    // Status + diff
    public let statusOK: RGBA
    public let statusWarn: RGBA
    public let statusError: RGBA
    public let diffAddedFg: RGBA
    public let diffRemovedFg: RGBA
    public let diffAddedBg: RGBA
    public let diffRemovedBg: RGBA
    /// Diff gutter line numbers on the editor surface (pierre's fg-number:
    /// 65% editor fg toward editor bg).
    public let diffLineNumberFg: RGBA

    public let terminal: TerminalPalette
}

public enum PaletteDeriver {
    // Mix weight (fraction of the surface's own foreground blended into its
    // background) for the opaque chrome borders and separators; shared so both
    // lines carry the same visual weight across themes.
    private static let borderMix = 0.22

    /// Reads a VSCode/Shiki theme and returns the derived palette, or nil for
    /// the degenerate case where the theme yields no parseable background or
    /// no legible foreground — real themes always produce both.
    public static func derive(from theme: VSCodeTheme) -> DerivedPalette? {
        let raw = theme.colors ?? [:]
        let resolved = ThemeNormalizer.normalize(theme).colors ?? [:]

        // The contrast pass needs the raw candidate list in design-intent
        // order, not the collapsed sidebar fg, so it can compare each
        // candidate against the surface.
        let sidebarBgHex = resolved["sideBar.background"]
        guard let sidebarBg = sidebarBgHex.flatMap({ RGBA(css: $0) }) else { return nil }
        guard
            let fgHex = ColorMath.pickReadableForeground(
                bg: sidebarBgHex,
                candidates: [raw["sideBar.foreground"], raw["editor.foreground"], theme.fg]
            ),
            let fgRaw = RGBA(css: fgHex)
        else { return nil }
        let fg = fgRaw.compositedOver(sidebarBg)

        let editorBg =
            resolved["editor.background"].flatMap { RGBA(css: $0) }?.compositedOver(sidebarBg)
            ?? sidebarBg
        let editorFg =
            resolved["editor.foreground"].flatMap { RGBA(css: $0) }?.compositedOver(editorBg)
            ?? fg

        let isDark = ColorMath.isDarkSurface(bg: sidebarBg.hexString(), fgHint: fg.hexString())

        let textSecondary =
            readableMuted(raw["descriptionForeground"], over: sidebarBg)
            ?? mutedFg(from: fg, over: sidebarBg)

        // Hairline between content panes: when the editor surface matches the
        // sidebar (the common case) reuse the chrome border verbatim so the
        // separator can't drift; only when the palettes genuinely diverge
        // derive it from the editor surface.
        let borderOpaque = fg.mixed(with: sidebarBg, weight: borderMix)
        let separator =
            ColorMath.surfacesMatch(editorBg.hexString(), sidebarBg.hexString())
            ? borderOpaque
            : editorFg.mixed(with: editorBg, weight: borderMix)

        let focusRing =
            resolved["list.focusOutline"].flatMap { RGBA(css: $0) }?.compositedOver(sidebarBg)
            ?? fg

        // Accent: the first authored accent-ish key that is visible and clears
        // the readable floor on the sidebar surface. `list.focusOutline` (the
        // normalized focus ring) is the last authored candidate; when nothing
        // authored qualifies the accent stays the focus-ring value, which is
        // the pre-existing behavior. Only an AUTHORED accent may tint the
        // hover/selection fallbacks below — the fg-fallback focus ring would
        // just reproduce a gray mix at a different weight.
        let authoredAccent = contrastingThemeColor(
            resolved,
            keys: ["focusBorder", "textLink.foreground", "button.background", "list.focusOutline"],
            over: [sidebarBg],
            minRatio: ColorMath.minReadableRatio
        )
        let accent = authoredAccent ?? focusRing

        // Row fills: the theme's authored hover/selection when present (the
        // normalizer already dropped unusable ones; selection is re-checked on
        // its composite), else an accent-tinted wash — pierre's look — else
        // the legacy gray fg-mix.
        let rowHover =
            themeColor(resolved, keys: ["list.hoverBackground"], over: sidebarBg)
            ?? authoredAccent.flatMap {
                accentRowFill($0, alpha: isDark ? 0.14 : 0.10, text: fg, base: sidebarBg)
            }
            ?? fg.mixed(with: sidebarBg, weight: 0.08)
        let rowSelected =
            themeColor(resolved, keys: ["list.activeSelectionBackground"], over: sidebarBg)
                .flatMap { usableRowFill($0, text: fg, base: sidebarBg) ? $0 : nil }
            ?? authoredAccent.flatMap {
                accentRowFill($0, alpha: isDark ? 0.28 : 0.22, text: fg, base: sidebarBg)
            }
            ?? fg.mixed(with: sidebarBg, weight: 0.14)

        // Elevated surfaces: the theme's authored widget/menu surface when it
        // is a genuinely different surface that keeps the fg legible, else the
        // derived fg-nudge. Some dark themes author widgets DARKER than the
        // sidebar (dracula, tokyo-night) — designer intent, honored.
        let authoredCard = authoredElevatedSurface(
            resolved, keys: ["editorWidget.background"], sidebarBg: sidebarBg, fg: fg)
        let cardBackground = authoredCard ?? fg.mixed(with: sidebarBg, weight: 0.06)
        // Hover must always move off the card base, so when the authored
        // surface wins the hover is derived FROM it rather than from the
        // sidebar.
        let cardHoverBackground =
            authoredCard.map { fg.mixed(with: $0, weight: 0.06) }
            ?? fg.mixed(with: sidebarBg, weight: 0.12)
        let popoverBackground =
            authoredElevatedSurface(
                resolved,
                keys: ["menu.background", "editorWidget.background", "dropdown.background"],
                sidebarBg: sidebarBg, fg: fg
            ) ?? fg.mixed(with: sidebarBg, weight: 0.07)

        // Status tints: the theme's own signal colors when they clear the
        // readable floor on EVERY surface they render on, else the
        // luminance-picked constants (same values as the web mapping).
        let statusSurfaces = [sidebarBg, editorBg, cardBackground]
        let statusOK =
            contrastingThemeColor(
                resolved,
                keys: [
                    "terminal.ansiGreen", "terminal.ansiBrightGreen",
                    "gitDecoration.addedResourceForeground",
                ],
                over: statusSurfaces, minRatio: ColorMath.minReadableRatio
            ) ?? constant(isDark ? "#34d399" : "#047857")
        let statusWarn =
            contrastingThemeColor(
                resolved,
                keys: [
                    "terminal.ansiYellow", "terminal.ansiBrightYellow",
                    "editorWarning.foreground",
                ],
                over: statusSurfaces, minRatio: ColorMath.minReadableRatio
            ) ?? constant(isDark ? "#f59e0b" : "#b45309")
        let statusError =
            contrastingThemeColor(
                resolved,
                keys: [
                    "terminal.ansiRed", "terminal.ansiBrightRed",
                    "editorError.foreground",
                ],
                over: statusSurfaces, minRatio: ColorMath.minReadableRatio
            ) ?? constant(isDark ? "#fb7185" : "#be123c")

        // Diff colors follow pierre's diffs package instead: bases from the
        // theme's git decorations (else its ANSI green/red, else pierre's
        // hardcoded fallbacks), and row backgrounds as an OPAQUE mix of the
        // editor surface toward the base — 12% light / 20% dark — so
        // highlighted code sits on exactly the surface the theme's token
        // colors were designed for.
        let additionBase =
            themeColor(
                resolved,
                keys: ["gitDecoration.addedResourceForeground", "terminal.ansiGreen"],
                over: editorBg
            ) ?? constant(isDark ? "#5ecc71" : "#0dbe4e")
        let deletionBase =
            themeColor(
                resolved,
                keys: ["gitDecoration.deletedResourceForeground", "terminal.ansiRed"],
                over: editorBg
            ) ?? constant(isDark ? "#ff6762" : "#ff2e3f")
        // mixed(weight:) keeps `weight` of the receiver: rows stay 80% (dark)
        // / 88% (light) editor bg with just a tint of the base color.
        let diffRowMix = isDark ? 0.8 : 0.88

        return DerivedPalette(
            isDark: isDark,
            windowBackground: editorBg,
            sidebarBackground: sidebarBg,
            cardBackground: cardBackground,
            cardHoverBackground: cardHoverBackground,
            cardBorder: fg.mixed(with: sidebarBg, weight: 0.12),
            popoverBackground: popoverBackground,
            popoverBorder: fg.mixed(with: sidebarBg, weight: 0.18),
            composerBackground: editorBg,
            bubbleBackground: fg.mixed(with: sidebarBg, weight: 0.08),
            paneHeaderBackground: fg.mixed(with: editorBg, weight: 0.06),
            textPrimary: fg,
            textSecondary: textSecondary,
            textTertiary: fg.mixed(with: sidebarBg, weight: 0.45),
            rowHoverBackground: rowHover,
            rowSelectedBackground: rowSelected,
            accent: accent,
            focusRing: focusRing,
            border: fg.withAlpha(0.2),
            borderOpaque: borderOpaque,
            separator: separator,
            statusOK: statusOK,
            statusWarn: statusWarn,
            statusError: statusError,
            diffAddedFg: additionBase,
            diffRemovedFg: deletionBase,
            diffAddedBg: editorBg.mixed(with: additionBase, weight: diffRowMix),
            diffRemovedBg: editorBg.mixed(with: deletionBase, weight: diffRowMix),
            diffLineNumberFg: editorFg.mixed(with: editorBg, weight: 0.65),
            terminal: terminalPalette(resolved: resolved, editorBg: editorBg, editorFg: editorFg)
        )
    }

    // First candidate among `keys` that is visible (not fully transparent) and,
    // composited over the FIRST surface, clears `minRatio` against every listed
    // surface; nil when none does. Used for colors that must read as signal on
    // all the surfaces they render on (accent, status).
    private static func contrastingThemeColor(
        _ colors: [String: String], keys: [String],
        over surfaces: [RGBA], minRatio: Double
    ) -> RGBA? {
        guard let base = surfaces.first else { return nil }
        for key in keys {
            guard
                let hex = colors[key],
                !ColorMath.isFullyTransparent(hex),
                let color = RGBA(css: hex)
            else { continue }
            let composited = color.compositedOver(base)
            let clearsAll = surfaces.allSatisfy {
                ColorMath.contrastRatio($0.relativeLuminance, composited.relativeLuminance)
                    >= minRatio
            }
            if clearsAll { return composited }
        }
        return nil
    }

    // A row fill is usable when the row text still reads on it (>= the primary
    // floor) and it isn't literally the base surface (an identical fill would
    // be invisible). Deliberately NOT a luminance-closeness test: subtle
    // authored washes on dark themes sit within a few luminance points of the
    // surface and are exactly the look we want to preserve.
    private static func usableRowFill(_ fill: RGBA, text: RGBA, base: RGBA) -> Bool {
        guard fill != base else { return false }
        return ColorMath.contrastRatio(fill.relativeLuminance, text.relativeLuminance)
            >= ColorMath.minReadableRatio
    }

    // The accent at `alpha` composited over the base surface, when that fill
    // is usable for a row; nil otherwise so the caller falls through.
    private static func accentRowFill(
        _ accent: RGBA, alpha: Double, text: RGBA, base: RGBA
    ) -> RGBA? {
        let fill = accent.withAlpha(alpha).compositedOver(base)
        return usableRowFill(fill, text: text, base: base) ? fill : nil
    }

    // First authored elevated-surface candidate that is a genuinely different
    // surface from the sidebar (exact-value compare on the composite — a ΔL
    // floor would reject every dark theme's elevation, since dark luminances
    // compress) and keeps the fg legible on it. Nil → derived fg-nudge.
    private static func authoredElevatedSurface(
        _ colors: [String: String], keys: [String], sidebarBg: RGBA, fg: RGBA
    ) -> RGBA? {
        for key in keys {
            guard let hex = colors[key], let color = RGBA(css: hex) else { continue }
            let composited = color.compositedOver(sidebarBg)
            guard composited != sidebarBg else { continue }
            guard
                ColorMath.contrastRatio(
                    composited.relativeLuminance, fg.relativeLuminance)
                    >= ColorMath.minReadableRatio
            else { continue }
            return composited
        }
        return nil
    }

    // First parseable color among `keys`, composited over the surface it will
    // render on; nil when the theme defines none of them.
    private static func themeColor(
        _ colors: [String: String], keys: [String], over bg: RGBA
    ) -> RGBA? {
        for key in keys {
            if let hex = colors[key], let color = RGBA(css: hex) {
                return color.compositedOver(bg)
            }
        }
        return nil
    }

    // Returns the theme's descriptionForeground composited over the surface
    // when it's readable enough (>= minMutedRatio), otherwise nil so the call
    // site falls back to a derived muted.
    private static func readableMuted(_ candidate: String?, over bg: RGBA) -> RGBA? {
        guard let candidate, let color = RGBA(css: candidate) else { return nil }
        let composited = color.compositedOver(bg)
        let ratio = ColorMath.contrastRatio(
            bg.relativeLuminance, composited.relativeLuminance)
        return ratio >= ColorMath.minMutedRatio ? composited : nil
    }

    // RGBA port of ColorMath.deriveMutedFg: mixes fg toward bg from 60% up to
    // 90% until the result clears the muted contrast floor, else keeps fg.
    private static func mutedFg(from fg: RGBA, over bg: RGBA) -> RGBA {
        let bgL = bg.relativeLuminance
        for weight in [0.6, 0.7, 0.8, 0.9] {
            let mixed = fg.mixed(with: bg, weight: weight)
            if ColorMath.contrastRatio(bgL, mixed.relativeLuminance) >= ColorMath.minMutedRatio {
                return mixed
            }
        }
        return fg
    }

    private static let ansiKeys = [
        "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen",
        "terminal.ansiYellow", "terminal.ansiBlue", "terminal.ansiMagenta",
        "terminal.ansiCyan", "terminal.ansiWhite", "terminal.ansiBrightBlack",
        "terminal.ansiBrightRed", "terminal.ansiBrightGreen", "terminal.ansiBrightYellow",
        "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta", "terminal.ansiBrightCyan",
        "terminal.ansiBrightWhite",
    ]

    private static func terminalPalette(
        resolved: [String: String],
        editorBg: RGBA,
        editorFg: RGBA
    ) -> TerminalPalette {
        let background =
            resolved["terminal.background"].flatMap { RGBA(css: $0) }?.compositedOver(editorBg)
            ?? editorBg
        let foreground =
            resolved["terminal.foreground"].flatMap { RGBA(css: $0) }?.compositedOver(background)
            ?? editorFg
        let cursor = (resolved["terminalCursor.foreground"] ?? resolved["editorCursor.foreground"])
            .flatMap { RGBA(css: $0) }?.compositedOver(background)
        let selectionBg = resolved["terminal.selectionBackground"]
            .flatMap { RGBA(css: $0) }?.compositedOver(background)
        let selectionFg = resolved["terminal.selectionForeground"]
            .flatMap { RGBA(css: $0) }
        return TerminalPalette(
            background: background,
            foreground: foreground,
            cursorColor: cursor,
            selectionBackground: selectionBg,
            selectionForeground: selectionFg,
            ansi: ansiKeys.map { key in
                resolved[key].flatMap { RGBA(css: $0) }?.compositedOver(background)
            }
        )
    }

    // Parses a compile-time hex constant; traps immediately on a typo rather
    // than propagating an optional through every palette field.
    private static func constant(_ hex: String) -> RGBA {
        guard let color = RGBA(hex: hex) else {
            preconditionFailure("Invalid palette constant \(hex)")
        }
        return color
    }
}
