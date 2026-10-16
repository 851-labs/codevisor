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
    #expect(fg.mixed(with: bg, weight: 0.06) == RGBA(r: 15, g: 15, b: 15))
    #expect(fg.mixed(with: bg, weight: 1) == RGBA(r: 255, g: 255, b: 255))
    #expect(fg.mixed(with: bg, weight: 0) == RGBA(r: 0, g: 0, b: 0))
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
