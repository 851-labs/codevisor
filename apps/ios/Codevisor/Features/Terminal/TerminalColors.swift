import CodevisorTheming
import CodevisorUI
import GhosttyTerminal
import SwiftUI
import UIKit

/// The terminal's colors for the current appearance, resolved once so the
/// emulator is only recolored when they actually change.
struct TerminalColors: Equatable {
  let background: UIColor
  let foreground: UIColor
  let cursor: UIColor
  let selection: UIColor?
  /// ANSI 0–15 as 0xRRGGBB: the theme's when it defines all sixteen,
  /// otherwise Ghostty's default.
  let ansi: [UInt32]?
  let isDark: Bool
  /// No terminal theme: the terminal sits on the app's own surface.
  let followsSystem: Bool

  init(palette: TerminalPalette?, colorScheme: ColorScheme) {
    let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    if let palette {
      background = Self.uiColor(palette.background)
      foreground = Self.uiColor(palette.foreground)
      cursor = palette.cursorColor.map { Self.uiColor($0) } ?? foreground
      selection = palette.selectionBackground.map { Self.uiColor($0) }
      let colors = palette.ansi.compactMap { $0 }
      ansi = colors.count == 16 ? colors.map { Self.hex($0) } : nil
      isDark = Self.luminance(palette.background) < 0.5
      followsSystem = false
    } else {
      // The chat's own surface, so terminals and chats sit on one color.
      background = UIColor.systemGroupedBackground.resolvedColor(with: traits)
      foreground = UIColor.label.resolvedColor(with: traits)
      cursor = foreground
      selection = nil
      // Ghostty's default palette, which macOS terminals use in either
      // appearance, so prompts and TUIs color the same on both platforms.
      ansi = Self.ghosttyANSI
      isDark = colorScheme == .dark
      followsSystem = true
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.background == rhs.background && lhs.foreground == rhs.foreground && lhs.cursor == rhs.cursor
      && lhs.selection == rhs.selection && lhs.isDark == rhs.isDark
      && lhs.ansi == rhs.ansi
  }

  private static func uiColor(_ rgba: RGBA) -> UIColor {
    UIColor(red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, alpha: rgba.a)
  }

  /// These colors as Ghostty configuration, at the app's terminal font size.
  /// Ghostty's compiled-in font (JetBrains Mono with Nerd Font symbols) is
  /// used as-is, matching the macOS app.
  func ghosttyConfiguration(fontSize: Float) -> TerminalConfiguration {
    TerminalConfiguration { builder in
      builder.withFontSize(fontSize)
      // Ghostty's ⌘K clears only this view; the app clears the server
      // terminal for every device instead (SessionTerminalView.onClear).
      builder.withCustom("keybind", "super+k=unbind")
      builder.withBackground(Self.hex(background))
      builder.withForeground(Self.hex(foreground))
      if followsSystem {
        // As on macOS: the cursor takes the color of the text under it, so it
        // stays visible on backgrounds programs paint themselves.
        builder.withCursorColor("cell-foreground")
        builder.withCursorText("cell-background")
      } else {
        builder.withCursorColor(Self.hex(cursor))
      }
      if let selection { builder.withSelectionBackground(Self.hex(selection)) }
      for (index, value) in (ansi ?? []).enumerated() {
        builder.withPalette(index, color: String(format: "#%06X", value))
      }
    }
  }

  private static func hex(_ color: UIColor) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func channel(_ value: CGFloat) -> Int { Int(max(0, min(255, (value * 255).rounded()))) }
    return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }

  private static func hex(_ rgba: RGBA) -> UInt32 {
    func channel(_ value: Double) -> UInt32 { UInt32(max(0, min(255, value.rounded()))) }
    return channel(rgba.r) << 16 | channel(rgba.g) << 8 | channel(rgba.b)
  }

  /// Ghostty's built-in ANSI 0–15 (Tomorrow Night), from libghostty's
  /// `terminal/color.zig`.
  static let ghosttyANSI: [UInt32] = [
    0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
    0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
  ]

  private static func luminance(_ rgba: RGBA) -> Double {
    (0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b) / 255
  }
}
