import CodevisorTheming
import SwiftUI
#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

public enum PullRequestPalette {
  public static let open = color(light: 0x1A7F37, dark: 0x3FB950)
  public static let pending = color(light: 0x9A6700, dark: 0xD29922)
  public static let failing = color(light: 0xCF222E, dark: 0xF85149)
  public static let closed = failing
  public static let merged = color(light: 0x8250DF, dark: 0xA371F7)
  public static let draft = color(light: 0x59636E, dark: 0x8B949E)

  private static func color(light: UInt32, dark: UInt32) -> Color {
    #if canImport(AppKit)
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          return NSColor(rgba: rgba(isDark ? dark : light))
        })
    #else
      Color(
        uiColor: UIColor { traits in
          let components = rgba(traits.userInterfaceStyle == .dark ? dark : light)
          return UIColor(
            red: components.r / 255, green: components.g / 255, blue: components.b / 255, alpha: components.a)
        })
    #endif
  }

  private static func rgba(_ hex: UInt32) -> RGBA {
    RGBA(r: Double(hex >> 16 & 0xFF), g: Double(hex >> 8 & 0xFF), b: Double(hex & 0xFF))
  }
}
