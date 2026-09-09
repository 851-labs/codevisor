#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import UIKit

  public typealias MarkdownNativeColor = UIColor
  typealias MarkdownNativeFont = UIFont
  typealias MarkdownNativeChipBackground = UIKitTextKitRoundedBackground

  enum MarkdownNativeTypography {
    static var linkColor: UIColor { .link }
    static var codeFont: UIFont { .scaledMonospacedSystemFont(forTextStyle: .callout) }
    static func installLink(_ link: URL, into attributes: inout [NSAttributedString.Key: Any]) {
      attributes[.link] = link
    }
    static func headingFont(for level: Int) -> UIFont {
      let style: UIFont.TextStyle =
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
      return styled(.preferredFont(forTextStyle: style), bold: true, italic: false)
    }

    static func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
      guard bold || italic else { return font }
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.traitBold) }
      if italic { traits.insert(.traitItalic) }
      guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
        return font
      }
      return UIFont(descriptor: descriptor, size: font.pointSize)
    }

  }
#endif
