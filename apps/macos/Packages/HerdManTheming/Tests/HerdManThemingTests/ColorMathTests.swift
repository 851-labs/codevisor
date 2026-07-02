import Foundation
import Testing

@testable import HerdManTheming

@Suite("RGBA parsing and math")
struct RGBATests {
    @Test("Hex parsing matrix")
    func hexParsing() {
        #expect(RGBA(hex: "#abc") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 1))
        #expect(RGBA(hex: "#aabbcc") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 1))
        #expect(RGBA(hex: "#aabbccdd")?.a != nil)
        #expect(RGBA(hex: "#aabbcc80")!.a > 0.5 && RGBA(hex: "#aabbcc80")!.a < 0.51)
        #expect(RGBA(hex: "#abcd") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 221.0 / 255.0))
        #expect(RGBA(hex: " #FFFFFF ") == RGBA(r: 255, g: 255, b: 255, a: 1))
        #expect(RGBA(hex: "aabbcc") == nil)
        #expect(RGBA(hex: "#xyzxyz") == nil)
        #expect(RGBA(hex: "#abcde") == nil)
        #expect(RGBA(hex: "") == nil)
        #expect(RGBA(hex: "rgb(0,0,0)") == nil)
    }

    @Test("Hex round-trip")
    func hexRoundTrip() {
        #expect(RGBA(hex: "#1e1e2e")!.hexString() == "#1e1e2e")
        #expect(RGBA(hex: "#1e1e2e80")!.hexString(includeAlpha: true) == "#1e1e2e80")
    }

    @Test("Luminance extremes and contrast")
    func luminanceAndContrast() {
        let white = RGBA(hex: "#ffffff")!
        let black = RGBA(hex: "#000000")!
        #expect(abs(white.relativeLuminance - 1.0) < 0.0001)
        #expect(abs(black.relativeLuminance - 0.0) < 0.0001)
        let ratio = ColorMath.contrastRatio(
            white.relativeLuminance, black.relativeLuminance)
        #expect(abs(ratio - 21.0) < 0.01)
        // Symmetry
        #expect(
            ColorMath.contrastRatio(0.2, 0.8) == ColorMath.contrastRatio(0.8, 0.2))
    }

    @Test("Mixing matches the CSS color-mix result")
    func mixing() {
        let fg = RGBA(hex: "#ffffff")!
        let bg = RGBA(hex: "#000000")!
        // color-mix(in srgb, #ffffff 6%, #000000) ≈ #0f0f0f
        #expect(fg.mixed(with: bg, weight: 0.06).hexString() == "#0f0f0f")
        #expect(fg.mixed(with: bg, weight: 1).hexString() == "#ffffff")
        #expect(fg.mixed(with: bg, weight: 0).hexString() == "#000000")
    }

    @Test("Compositing semi-transparent colors")
    func compositing() {
        let translucent = RGBA(hex: "#ffffff80")!
        let over = translucent.compositedOver(RGBA(hex: "#000000")!)
        #expect(over.a == 1)
        // ~50% white over black
        #expect(abs(over.r - 128) <= 1)
        #expect(ColorMath.compositeOverBg("#ffffff80", over: "#000000") == over.hexString())
        #expect(ColorMath.compositeOverBg("#ffffff", over: nil) == nil)
    }
}

@Suite("ColorMath predicates")
struct ColorMathTests {
    @Test("isFullyTransparent")
    func fullyTransparent() {
        #expect(ColorMath.isFullyTransparent("transparent"))
        #expect(ColorMath.isFullyTransparent("Transparent "))
        #expect(ColorMath.isFullyTransparent("#fff0"))
        #expect(ColorMath.isFullyTransparent("#ffffff00"))
        #expect(ColorMath.isFullyTransparent("rgba(0, 0, 0, 0)"))
        #expect(ColorMath.isFullyTransparent("rgb(0 0 0 / 0)"))
        #expect(ColorMath.isFullyTransparent("rgb(0 0 0 / 0%)"))
        #expect(ColorMath.isFullyTransparent("hsla(210, 40%, 50%, 0.0)"))
        #expect(!ColorMath.isFullyTransparent("#ffffff"))
        #expect(!ColorMath.isFullyTransparent("#fff"))
        #expect(!ColorMath.isFullyTransparent("#ffffff01"))
        #expect(!ColorMath.isFullyTransparent("rgba(0,0,0,0.5)"))
        #expect(!ColorMath.isFullyTransparent(nil))
        #expect(!ColorMath.isFullyTransparent("notacolor"))
    }

    @Test("isDarkSurface")
    func darkSurface() {
        #expect(ColorMath.isDarkSurface(bg: "#1e1e2e"))
        #expect(!ColorMath.isDarkSurface(bg: "#f8f8f8"))
        // Unparseable bg falls back to the fg hint: light fg → dark surface.
        #expect(ColorMath.isDarkSurface(bg: nil, fgHint: "#eeeeee"))
        #expect(!ColorMath.isDarkSurface(bg: nil, fgHint: "#111111"))
        #expect(!ColorMath.isDarkSurface(bg: nil, fgHint: nil))
    }

    @Test("surfacesMatch")
    func surfaces() {
        #expect(ColorMath.surfacesMatch("#ABCDEF", "#abcdef"))
        #expect(ColorMath.surfacesMatch("#101010", "#141414"))  // Δ luminance < 0.06
        #expect(!ColorMath.surfacesMatch("#000000", "#ffffff"))
        #expect(!ColorMath.surfacesMatch(nil, "#ffffff"))
    }

    @Test("hoverWouldEraseText truth table")
    func hoverErase() {
        // Hover close to fg → erases.
        #expect(ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: "#111111", fg: "#ffffff"))
        // Hover close to bg → fine.
        #expect(!ColorMath.hoverWouldEraseText(hover: "#1a1a1a", bg: "#111111", fg: "#ffffff"))
        // Missing inputs → trust the theme.
        #expect(!ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: nil, fg: "#ffffff"))
        #expect(!ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: "#111111", fg: nil))
    }

    @Test("pickReadableForeground")
    func pickForeground() {
        // First candidate clearing 3:1 wins.
        #expect(
            ColorMath.pickReadableForeground(
                bg: "#000000", candidates: ["#333333", "#cccccc", "#ffffff"]) == "#cccccc")
        // Nothing clears the bar → highest contrast wins.
        #expect(
            ColorMath.pickReadableForeground(
                bg: "#000000", candidates: ["#111111", "#222222"]) == "#222222")
        // Unparseable bg → first defined candidate.
        #expect(
            ColorMath.pickReadableForeground(bg: nil, candidates: [nil, "", "#abc"]) == "#abc")
        #expect(ColorMath.pickReadableForeground(bg: "#000000", candidates: [nil, nil]) == nil)
    }

    @Test("deriveMutedFg clears the muted floor")
    func mutedFg() {
        let muted = ColorMath.deriveMutedFg(primaryFg: "#ffffff", bg: "#000000")
        let ratio = ColorMath.contrastRatio(
            ColorMath.relativeLuminance(muted)!, ColorMath.relativeLuminance("#000000")!)
        #expect(ratio >= ColorMath.minMutedRatio)
        // The 60% mix of white over black already clears 4.5 → expect that mix.
        #expect(muted == "#999999")
        // Unparseable input → primary passthrough.
        #expect(ColorMath.deriveMutedFg(primaryFg: "var(--fg)", bg: "#000") == "var(--fg)")
        #expect(ColorMath.deriveMutedFg(primaryFg: "#fff", bg: nil) == "#fff")
    }
}
