import Foundation
import Testing

@testable import HerdManTheming

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
        // Dark-surface status constants.
        #expect(palette.statusOK == RGBA(hex: "#34d399"))
        #expect(palette.statusError == RGBA(hex: "#fb7185"))
        #expect(palette.statusWarn == RGBA(hex: "#f59e0b"))
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
