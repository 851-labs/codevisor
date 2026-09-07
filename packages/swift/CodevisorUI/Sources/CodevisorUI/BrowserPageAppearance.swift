import SwiftUI

#if os(iOS)
  import UIKit
  typealias BrowserPlatformColor = UIColor
#else
  import AppKit
  typealias BrowserPlatformColor = NSColor
#endif

/// WebKit supplies both colors and observes CSS / theme-color changes for us.
/// The page owns its overscroll color; theme-color styles the surrounding UI.
struct BrowserPageAppearance: Equatable {
  var chromeColor: Color = .clear
  var chromeScheme: ColorScheme = .light

  init() {}

  init(background: BrowserPlatformColor, theme: BrowserPlatformColor?) {
    let background = Self.components(background)
    let theme = Self.components(theme ?? .clear)
    let channels = zip(theme.prefix(3), background.prefix(3)).map { foreground, backdrop in
      foreground * theme[3] + (backdrop * background[3] + 1 - background[3]) * (1 - theme[3])
    }
    chromeColor = Color(.sRGB, red: channels[0], green: channels[1], blue: channels[2], opacity: 1)
    let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    // Choose whichever foreground (black or white) has greater contrast.
    chromeScheme = luminance < 0.179 ? .dark : .light
  }

  private static func components(_ color: BrowserPlatformColor) -> [Double] {
    #if os(iOS)
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      return [red, green, blue, alpha].map(Double.init)
    #else
      let rgb = color.usingColorSpace(.sRGB) ?? .white
      return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map(Double.init)
    #endif
  }
}
