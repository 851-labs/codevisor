#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public typealias MarkdownNativeColor = NSColor
  typealias MarkdownNativeFont = NSFont
  typealias MarkdownNativeChipBackground = TextKitRoundedBackground

  enum MarkdownNativeTypography {
    static var linkColor: NSColor { .linkColor }
    static var codeFont: NSFont {
      .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    }
    static func installLink(_ link: URL, into attributes: inout [NSAttributedString.Key: Any]) {
      if markdownUsesServerFileLinkAttribute(link) {
        attributes[.streamMarkdownServerFileLink] = link
        attributes[.cursor] = NSCursor.pointingHand
      } else {
        attributes[.link] = link
      }
    }
    /// Each level's text style at that style's emphasized weight from the
    /// HIG's macOS text style table (Headline is bold already).
    static func headingFont(for level: Int) -> NSFont {
      let (style, weight): (NSFont.TextStyle, NSFont.Weight) =
        switch level {
        case 1: (.title1, .bold)
        case 2: (.title2, .bold)
        case 3: (.title3, .semibold)
        case 4: (.headline, .bold)
        default: (.subheadline, .semibold)
        }
      return .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
      guard bold || italic else { return font }
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.bold) }
      if italic { traits.insert(.italic) }
      let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
      return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

  }
#endif
