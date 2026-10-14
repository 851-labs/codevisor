import Foundation
import Testing

@testable import CodevisorTheming

@Suite("RGBA parsing and math")
struct RGBATests {
  @Test("Hex parsing matrix")
  func hexParsing() {
    #expect(RGBA(hex: "#abc") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 1))
    #expect(RGBA(hex: "#aabbcc") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 1))
    #expect(RGBA(hex: "#aabbccdd") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 221.0 / 255.0))
    #expect(RGBA(hex: "#aabbcc80") == RGBA(r: 0xAA, g: 0xBB, b: 0xCC, a: 128.0 / 255.0))
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
    #expect(
      ColorMath.contrastRatio(0.2, 0.8) == ColorMath.contrastRatio(0.8, 0.2))
  }

  @Test("Mixing matches the CSS color-mix result")
  func mixing() {
    let fg = RGBA(hex: "#ffffff")!
    let bg = RGBA(hex: "#000000")!
    #expect(fg.mixed(with: bg, weight: 0.06).hexString() == "#0f0f0f")
    #expect(fg.mixed(with: bg, weight: 1).hexString() == "#ffffff")
    #expect(fg.mixed(with: bg, weight: 0).hexString() == "#000000")
  }

  @Test("Compositing semi-transparent colors")
  func compositing() {
    let translucent = RGBA(hex: "#ffffff80")!
    let over = translucent.compositedOver(RGBA(hex: "#000000")!)
    #expect(over == RGBA(r: 128, g: 128, b: 128, a: 1))
    #expect(ColorMath.compositeOverBg("#ffffff80", over: "#000000") == "#808080")
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
    #expect(ColorMath.isDarkSurface(bg: nil, fgHint: "#eeeeee"))
    #expect(!ColorMath.isDarkSurface(bg: nil, fgHint: "#111111"))
    #expect(!ColorMath.isDarkSurface(bg: nil, fgHint: nil))
  }

  @Test("surfacesMatch")
  func surfaces() {
    #expect(ColorMath.surfacesMatch("#ABCDEF", "#abcdef"))
    #expect(ColorMath.surfacesMatch("#101010", "#141414"))
    #expect(!ColorMath.surfacesMatch("#000000", "#ffffff"))
    #expect(!ColorMath.surfacesMatch(nil, "#ffffff"))
  }

  @Test("hoverWouldEraseText truth table")
  func hoverErase() {
    #expect(ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: "#111111", fg: "#ffffff"))
    #expect(!ColorMath.hoverWouldEraseText(hover: "#1a1a1a", bg: "#111111", fg: "#ffffff"))
    #expect(!ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: nil, fg: "#ffffff"))
    #expect(!ColorMath.hoverWouldEraseText(hover: "#eeeeee", bg: "#111111", fg: nil))
  }

  @Test("pickReadableForeground")
  func pickForeground() {
    #expect(
      ColorMath.pickReadableForeground(
        bg: "#000000", candidates: ["#333333", "#cccccc", "#ffffff"]) == "#cccccc")
    #expect(
      ColorMath.pickReadableForeground(
        bg: "#000000", candidates: ["#111111", "#222222"]) == "#222222")
    #expect(
      ColorMath.pickReadableForeground(bg: nil, candidates: [nil, "", "#abc"]) == "#abc")
    #expect(ColorMath.pickReadableForeground(bg: "#000000", candidates: [nil, nil]) == nil)
  }
}
