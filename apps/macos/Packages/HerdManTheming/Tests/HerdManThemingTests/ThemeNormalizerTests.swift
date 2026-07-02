import Foundation
import Testing

@testable import HerdManTheming

@Suite("ThemeNormalizer")
struct ThemeNormalizerTests {
    @Test("Minimal bg/fg theme fills the surface chains")
    func minimalTheme() {
        let theme = VSCodeTheme(name: "minimal", type: "dark", fg: "#e0e0e0", bg: "#101010")
        let colors = ThemeNormalizer.normalize(theme).colors ?? [:]
        #expect(colors["editor.background"] == "#101010")
        #expect(colors["editor.foreground"] == "#e0e0e0")
        #expect(colors["sideBar.background"] == "#101010")
        #expect(colors["sideBar.foreground"] == "#e0e0e0")
        #expect(colors["input.background"] == "#101010")
        #expect(colors["sideBarSectionHeader.foreground"] == "#e0e0e0")
        #expect(colors["list.activeSelectionForeground"] == "#e0e0e0")
    }

    @Test("Explicit values are honored over the chain")
    func explicitValues() {
        let theme = VSCodeTheme(
            type: "dark",
            colors: [
                "editor.background": "#111111",
                "sideBar.background": "#222222",
                "sideBar.foreground": "#dddddd",
            ],
            fg: "#ffffff",
            bg: "#000000"
        )
        let colors = ThemeNormalizer.normalize(theme).colors ?? [:]
        #expect(colors["editor.background"] == "#111111")
        #expect(colors["sideBar.background"] == "#222222")
        #expect(colors["sideBar.foreground"] == "#dddddd")
        #expect(colors["editor.foreground"] == "#ffffff")
    }

    @Test("Git decoration falls through ansi to gutter")
    func gitChains() {
        let ansiTheme = VSCodeTheme(
            type: "dark",
            colors: [
                "terminal.ansiGreen": "#00ff00",
                "terminal.ansiRed": "#ff0000",
                "terminal.ansiBlue": "#0000ff",
            ],
            fg: "#fff", bg: "#000"
        )
        let ansiColors = ThemeNormalizer.normalize(ansiTheme).colors ?? [:]
        #expect(ansiColors["gitDecoration.addedResourceForeground"] == "#00ff00")
        #expect(ansiColors["gitDecoration.modifiedResourceForeground"] == "#0000ff")
        #expect(ansiColors["gitDecoration.deletedResourceForeground"] == "#ff0000")

        let gutterTheme = VSCodeTheme(
            type: "dark",
            colors: [
                "editorGutter.addedBackground": "#11aa11",
                // Blank ansi key falls through to the gutter tier.
                "terminal.ansiGreen": ""
            ],
            fg: "#fff", bg: "#000"
        )
        let gutterColors = ThemeNormalizer.normalize(gutterTheme).colors ?? [:]
        #expect(gutterColors["gitDecoration.addedResourceForeground"] == "#11aa11")

        let explicit = VSCodeTheme(
            type: "dark",
            colors: [
                "gitDecoration.addedResourceForeground": "#abcabc",
                "terminal.ansiGreen": "#00ff00",
            ],
            fg: "#fff", bg: "#000"
        )
        #expect(
            ThemeNormalizer.normalize(explicit).colors?["gitDecoration.addedResourceForeground"]
                == "#abcabc")
    }

    @Test("Focus ring skips transparent outlines")
    func focusRing() {
        let transparentOutline = VSCodeTheme(
            type: "dark",
            colors: [
                "list.focusOutline": "#ffffff00",
                "focusBorder": "#3366ff",
            ],
            fg: "#fff", bg: "#000"
        )
        #expect(
            ThemeNormalizer.normalize(transparentOutline).colors?["list.focusOutline"]
                == "#3366ff")

        let bothTransparent = VSCodeTheme(
            type: "dark",
            colors: [
                "list.focusOutline": "transparent",
                "focusBorder": "#fff0",
            ],
            fg: "#fff", bg: "#000"
        )
        #expect(ThemeNormalizer.normalize(bothTransparent).colors?["list.focusOutline"] == nil)
    }

    @Test("Hover repair drops same-surface and text-erasing hovers")
    func hoverRepair() {
        let sameSurface = VSCodeTheme(
            type: "dark",
            colors: ["list.hoverBackground": "#101010"],
            fg: "#e0e0e0", bg: "#101010"
        )
        #expect(ThemeNormalizer.normalize(sameSurface).colors?["list.hoverBackground"] == nil)

        let erasing = VSCodeTheme(
            type: "dark",
            colors: ["list.hoverBackground": "#f0f0f0"],
            fg: "#ffffff", bg: "#101010"
        )
        #expect(ThemeNormalizer.normalize(erasing).colors?["list.hoverBackground"] == nil)

        let healthy = VSCodeTheme(
            type: "dark",
            colors: ["list.hoverBackground": "#202020"],
            fg: "#ffffff", bg: "#101010"
        )
        #expect(ThemeNormalizer.normalize(healthy).colors?["list.hoverBackground"] == "#202020")
    }

    @Test("Idempotency")
    func idempotency() {
        let theme = VSCodeTheme(
            name: "t", type: "dark",
            colors: [
                "list.hoverBackground": "#181818",
                "terminal.ansiGreen": "#00ff00",
                "focusBorder": "#3366ff",
            ],
            fg: "#e0e0e0", bg: "#101010"
        )
        let once = ThemeNormalizer.normalize(theme)
        let twice = ThemeNormalizer.normalize(once)
        #expect(once == twice)
    }
}
