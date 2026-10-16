import CodevisorTheming
import SwiftUI
#if canImport(AppKit)
  import AppKit
#endif

extension Color {
  public init(rgba: RGBA) {
    self.init(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a)
  }
}

#if canImport(AppKit)
  extension NSColor {
    public convenience init(rgba: RGBA) {
      self.init(
        srgbRed: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, alpha: rgba.a)
    }
  }
#endif

extension Color {
  public static var windowBackgroundColor: Color {
    #if canImport(AppKit)
      Color(nsColor: .windowBackgroundColor)
    #else
      Color(uiColor: .systemBackground)
    #endif
  }

  public static var tertiaryLabelColor: Color {
    #if canImport(AppKit)
      Color(nsColor: .tertiaryLabelColor)
    #else
      Color(uiColor: .tertiaryLabel)
    #endif
  }

  public static var cardBackgroundColor: Color {
    #if canImport(AppKit)
      Color(nsColor: .cardBackgroundColor)
    #else
      Color(uiColor: .quaternaryLabel).opacity(cardFillOpacity)
    #endif
  }

  public static var bubbleBackground: Color { Color.primary.opacity(0.08) }

  public static var separatorColor: Color {
    #if canImport(AppKit)
      Color(nsColor: .separatorColor)
    #else
      Color(uiColor: .separator)
    #endif
  }
}

private let cardFillOpacity: CGFloat = 0.4

#if canImport(AppKit)
  extension NSColor {
    public static var cardBackgroundColor: NSColor {
      NSColor(name: nil) { _ in
        let base = NSColor.quaternaryLabelColor.usingColorSpace(.sRGB) ?? .quaternaryLabelColor
        return base.withAlphaComponent(base.alphaComponent * cardFillOpacity)
      }
    }
  }
#endif
