import Foundation
import Testing

@testable import CodevisorTheming

@Suite("PaletteDeriver")
struct PaletteDeriverTests {
    private let darkTheme = VSCodeTheme(
        name: "test-dark", type: "dark",
        colors: [
            "editor.background": "#1e1e2e",
            "editor.foreground": "#cdd6f4",
            "sideBar.background": "#181825",
            "sideBar.foreground": "#cdd6f4",
            "descriptionForeground": "#a6adc8",
            "focusBorder": "#89b4fa",
            "terminal.ansiGreen": "#a6e3a1",
            "terminal.ansiRed": "#f38ba8",
        ]
    )

    @Test("Dark theme derives a legible palette")
    func darkPalette() throws {
        let palette = try #require(PaletteDeriver.derive(from: darkTheme))
        #expect(palette.isDark)
        #expect(palette.sidebarBackground == RGBA(hex: "#181825"))
        #expect(palette.windowBackground == RGBA(hex: "#1e1e2e"))
        #expect(palette.composerBackground == RGBA(hex: "#1e1e2e"))
        #expect(palette.textPrimary == RGBA(hex: "#cdd6f4"))
        // descriptionForeground clears 4.5:1 on this surface → kept.
        #expect(palette.textSecondary == RGBA(hex: "#a6adc8"))
        #expect(palette.accent == RGBA(hex: "#89b4fa"))
        // The theme's ANSI green/red clear 3:1 on every status surface → they
        // ARE the status tints; no yellow is authored → warn keeps the
        // dark-surface constant.
        #expect(palette.statusOK == RGBA(hex: "#a6e3a1"))
        #expect(palette.statusError == RGBA(hex: "#f38ba8"))
        #expect(palette.statusWarn == RGBA(hex: "#f59e0b"))
        // No authored hover/selection, but focusBorder is an authored accent →
        // the row fills are accent-tinted washes, not gray mixes.
        let sidebarBg = try #require(RGBA(hex: "#181825"))
        let accent = try #require(RGBA(hex: "#89b4fa"))
        #expect(palette.rowHoverBackground == accent.withAlpha(0.14).compositedOver(sidebarBg))
        #expect(
            palette.rowSelectedBackground == accent.withAlpha(0.28).compositedOver(sidebarBg))
        // Diff bases come from the theme (ANSI green/red here, no git
        // decorations) and row backgrounds are opaque editor-bg mixes.
        #expect(palette.diffAddedFg == RGBA(hex: "#a6e3a1"))
        #expect(palette.diffRemovedFg == RGBA(hex: "#f38ba8"))
        let editorBg = try #require(RGBA(hex: "#1e1e2e"))
        let ansiGreen = try #require(RGBA(hex: "#a6e3a1"))
        #expect(palette.diffAddedBg == editorBg.mixed(with: ansiGreen, weight: 0.8))
        #expect(palette.diffAddedBg.a == 1)
        // The row tint must stay a subtle wash of the surface, not a bright
        // fill the code drowns in: still much closer to bg than to the base.
        let editorBgL = editorBg.relativeLuminance
        #expect(abs(palette.diffAddedBg.relativeLuminance - editorBgL) < 0.1)
        // Contrast floors: primary >= 3:1, secondary >= 4.5:1 vs sidebar bg.
        let bgL = palette.sidebarBackground.relativeLuminance
        #expect(
            ColorMath.contrastRatio(bgL, palette.textPrimary.relativeLuminance)
                >= ColorMath.minReadableRatio)
        #expect(
            ColorMath.contrastRatio(bgL, palette.textSecondary.relativeLuminance)
                >= ColorMath.minMutedRatio)
    }

    @Test("Light theme picks light-surface status constants")
    func lightPalette() throws {
        let theme = VSCodeTheme(
            name: "test-light", type: "light", fg: "#24292e", bg: "#ffffff")
        let palette = try #require(PaletteDeriver.derive(from: theme))
        #expect(!palette.isDark)
        #expect(palette.statusOK == RGBA(hex: "#047857"))
        #expect(palette.statusError == RGBA(hex: "#be123c"))
        #expect(palette.statusWarn == RGBA(hex: "#b45309"))
        // No git/ANSI colors in the theme → pierre's light fallbacks.
        #expect(palette.diffAddedFg == RGBA(hex: "#0dbe4e"))
        #expect(palette.diffRemovedFg == RGBA(hex: "#ff2e3f"))
    }

    @Test("Git decoration colors outrank ANSI for diff bases")
    func diffBasePriority() throws {
        let theme = VSCodeTheme(
            type: "dark",
            colors: [
                "gitDecoration.addedResourceForeground": "#00ff88",
                "gitDecoration.deletedResourceForeground": "#ff0044",
                "terminal.ansiGreen": "#a6e3a1",
                "terminal.ansiRed": "#f38ba8",
            ],
            fg: "#cdd6f4", bg: "#1e1e2e"
        )
        let palette = try #require(PaletteDeriver.derive(from: theme))
        #expect(palette.diffAddedFg == RGBA(hex: "#00ff88"))
        #expect(palette.diffRemovedFg == RGBA(hex: "#ff0044"))
    }

    @Test("Degenerate themes yield nil")
    func degenerate() {
        // bg-only: no foreground anywhere.
        #expect(PaletteDeriver.derive(from: VSCodeTheme(type: "dark", bg: "#101010")) == nil)
        // Nothing at all.
        #expect(PaletteDeriver.derive(from: VSCodeTheme()) == nil)
        // Unparseable bg.
        #expect(
            PaletteDeriver.derive(
                from: VSCodeTheme(type: "dark", fg: "#fff", bg: "var(--bg)")) == nil)
    }

    @Test("Semi-transparent muted foreground is composited before measuring")
    func alphaMuted() throws {
        // aurora-x style: descriptionForeground with alpha that fails AA on its
        // own → falls back to derived muted, which must clear the floor.
        let theme = VSCodeTheme(
            type: "dark",
            colors: ["descriptionForeground": "#576daf30"],
            fg: "#bdbdbd", bg: "#07090f"
        )
        let palette = try #require(PaletteDeriver.derive(from: theme))
        let ratio = ColorMath.contrastRatio(
            palette.sidebarBackground.relativeLuminance,
            palette.textSecondary.relativeLuminance)
        #expect(ratio >= ColorMath.minMutedRatio)
    }

    @Test("Separator reuses the chrome border when surfaces match")
    func separator() throws {
        let sameSurfaces = VSCodeTheme(type: "dark", fg: "#e0e0e0", bg: "#101010")
        let same = try #require(PaletteDeriver.derive(from: sameSurfaces))
        #expect(same.separator == same.borderOpaque)

        let split = VSCodeTheme(
            type: "dark",
            colors: [
                "editor.background": "#1e1e2e",
                "sideBar.background": "#585868",
            ],
            fg: "#cdd6f4"
        )
        let diverged = try #require(PaletteDeriver.derive(from: split))
        #expect(diverged.separator != diverged.borderOpaque)
    }

    @Test("Terminal palette maps ANSI slots and falls back to editor colors")
    func terminalPalette() throws {
        let palette = try #require(PaletteDeriver.derive(from: darkTheme))
        // No terminal.background in the theme → editor bg.
        #expect(palette.terminal.background == RGBA(hex: "#1e1e2e"))
        #expect(palette.terminal.foreground == RGBA(hex: "#cdd6f4"))
        #expect(palette.terminal.ansi.count == 16)
        // ansiGreen is slot 2, ansiRed is slot 1.
        #expect(palette.terminal.ansi[2] == RGBA(hex: "#a6e3a1"))
        #expect(palette.terminal.ansi[1] == RGBA(hex: "#f38ba8"))
        #expect(palette.terminal.ansi[0] == nil)
    }

    @Test("Authored row fills win and are composited opaque")
    func authoredRowFills() throws {
        // dracula-style: semi-transparent hover, opaque selection.
        let theme = VSCodeTheme(
            type: "dark",
            colors: [
                "editor.background": "#282A36",
                "sideBar.background": "#21222C",
                "list.hoverBackground": "#44475A75",
                "list.activeSelectionBackground": "#44475A",
            ],
            fg: "#F8F8F2"
        )
        let palette = try #require(PaletteDeriver.derive(from: theme))
        let sidebarBg = try #require(RGBA(hex: "#21222C"))
        let hover = try #require(RGBA(hex: "#44475A75"))
        #expect(palette.rowHoverBackground == hover.compositedOver(sidebarBg))
        #expect(palette.rowHoverBackground.a == 1)
        #expect(palette.rowSelectedBackground == RGBA(hex: "#44475A"))
    }

    @Test("Accent chain: focusBorder wins, low-contrast falls through, transparent skipped")
    func accentChain() throws {
        let direct = try #require(
            PaletteDeriver.derive(
                from: VSCodeTheme(
                    type: "dark",
                    colors: [
                        "focusBorder": "#009fff",
                        "textLink.foreground": "#ff0000",
                    ],
                    fg: "#fafafa", bg: "#171717")))
        #expect(direct.accent == RGBA(hex: "#009fff"))

        // one-dark-pro style: gray focusBorder (~1.4:1) is not an accent —
        // fall through to the link blue. The focus RING still honors the
        // authored focusBorder (via the normalizer), so ring != accent here.
        let grayBorder = try #require(
            PaletteDeriver.derive(
                from: VSCodeTheme(
                    type: "dark",
                    colors: [
                        "focusBorder": "#3e4452",
                        "textLink.foreground": "#61afef",
                    ],
                    fg: "#abb2bf", bg: "#282c34")))
        #expect(grayBorder.accent == RGBA(hex: "#61afef"))
        #expect(grayBorder.focusRing == RGBA(hex: "#3e4452"))

        let transparentBorder = try #require(
            PaletteDeriver.derive(
                from: VSCodeTheme(
                    type: "dark",
                    colors: [
                        "focusBorder": "#ffffff00",
                        "button.background": "#5294e2",
                    ],
                    fg: "#e0e0e0", bg: "#101010")))
        #expect(transparentBorder.accent == RGBA(hex: "#5294e2"))
    }

    @Test("No authored accent keeps the legacy gray row mixes")
    func legacyRowFills() throws {
        let theme = VSCodeTheme(type: "dark", fg: "#e0e0e0", bg: "#101010")
        let palette = try #require(PaletteDeriver.derive(from: theme))
        let fg = try #require(RGBA(hex: "#e0e0e0"))
        let bg = try #require(RGBA(hex: "#101010"))
        #expect(palette.rowHoverBackground == fg.mixed(with: bg, weight: 0.08))
        #expect(palette.rowSelectedBackground == fg.mixed(with: bg, weight: 0.14))
        #expect(palette.accent == fg)
    }

    @Test("Authored elevated surfaces win when genuinely distinct and legible")
    func elevatedSurfaces() throws {
        // tokyo-night style: widget DARKER than the sidebar — designer intent.
        let authored = try #require(
            PaletteDeriver.derive(
                from: VSCodeTheme(
                    type: "dark",
                    colors: [
                        "sideBar.background": "#16161e",
                        "editorWidget.background": "#1a1b26",
                        "menu.background": "#1f2335",
                    ],
                    fg: "#c0caf5", bg: "#1a1b26")))
        #expect(authored.cardBackground == RGBA(hex: "#1a1b26"))
        #expect(authored.popoverBackground == RGBA(hex: "#1f2335"))
        // Hover always moves off the authored card base.
        let fg = try #require(RGBA(hex: "#c0caf5"))
        let card = try #require(RGBA(hex: "#1a1b26"))
        #expect(authored.cardHoverBackground == fg.mixed(with: card, weight: 0.06))

        // A widget equal to the sidebar adds no elevation → derived nudge.
        let flat = try #require(
            PaletteDeriver.derive(
                from: VSCodeTheme(
                    type: "dark",
                    colors: [
                        "sideBar.background": "#101010",
                        "editorWidget.background": "#101010",
                        "menu.background": "#101010",
                    ],
                    fg: "#e0e0e0", bg: "#101010")))
        let flatFg = try #require(RGBA(hex: "#e0e0e0"))
        let flatBg = try #require(RGBA(hex: "#101010"))
        #expect(flat.cardBackground == flatFg.mixed(with: flatBg, weight: 0.06))
        #expect(flat.popoverBackground == flatFg.mixed(with: flatBg, weight: 0.07))
    }

    @Test("Status tints fall back to constants when theme signals miss the floor")
    func statusFloor() throws {
        // solarized-light style: ansiGreen #859900 is ~2.98:1 on #FDF6E3 —
        // just under the floor → the light constant wins.
        let theme = VSCodeTheme(
            type: "light",
            colors: ["terminal.ansiGreen": "#859900"],
            fg: "#586e75", bg: "#FDF6E3"
        )
        let palette = try #require(PaletteDeriver.derive(from: theme))
        #expect(palette.statusOK == RGBA(hex: "#047857"))
    }

    @Test("VSCodeTheme type inference")
    func typeInference() {
        #expect(VSCodeTheme(type: "dark").resolvedIsDark)
        #expect(!VSCodeTheme(type: "light", bg: "#000").resolvedIsDark)
        #expect(VSCodeTheme(bg: "#101010").resolvedIsDark)
        #expect(!VSCodeTheme(bg: "#fafafa").resolvedIsDark)
        #expect(!VSCodeTheme().resolvedIsDark)
    }

    @Test("Decoding real VSCode theme JSON ignores unknown keys")
    func decoding() throws {
        let json = """
            {
              "name": "sample",
              "type": "dark",
              "semanticHighlighting": true,
              "colors": { "editor.background": "#1e1e1e", "editor.foreground": "#d4d4d4" },
              "tokenColors": [ { "scope": "comment", "settings": { "foreground": "#6a9955" } } ]
            }
            """
        let theme = try VSCodeTheme.decode(from: Data(json.utf8))
        #expect(theme.name == "sample")
        #expect(theme.colors?["editor.background"] == "#1e1e1e")
        #expect(theme.hasColorData)
        #expect(PaletteDeriver.derive(from: theme) != nil)
    }
}
