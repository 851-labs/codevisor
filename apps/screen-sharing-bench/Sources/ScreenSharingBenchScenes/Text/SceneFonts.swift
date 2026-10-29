import CoreGraphics
import CoreText
import Foundation

enum SceneFonts {
  static let monospaceName = "Menlo"

  static func monospace(pixels: CGFloat) -> CTFont {
    CTFontCreateWithName(monospaceName as CFString, pixels, nil)
  }

  static func system(pixels: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(.system, pixels, nil) ?? monospace(pixels: pixels)
  }

  static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
  }

  static func ascent(of font: CTFont) -> CGFloat {
    CTFontGetAscent(font).rounded(.up)
  }
}
