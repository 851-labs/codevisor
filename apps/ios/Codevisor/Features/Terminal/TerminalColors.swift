import CodevisorTheming
import CodevisorUI
import SwiftTerm
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

  init(palette: TerminalPalette?, colorScheme: ColorScheme) {
    let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    if let palette {
      background = Self.uiColor(palette.background)
      foreground = Self.uiColor(palette.foreground)
      cursor = palette.cursorColor.map(Self.uiColor) ?? foreground
      selection = palette.selectionBackground.map(Self.uiColor)
      let colors = palette.ansi.compactMap { $0 }
      ansi = colors.count == 16 ? colors.map(Self.hex) : nil
      isDark = Self.luminance(palette.background) < 0.5
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

  /// SwiftTerm's palette entries (16-bit channels).
  var terminalANSI: [SwiftTerm.Color]? {
    ansi?.map { value in
      SwiftTerm.Color(
        red: UInt16((value >> 16) & 0xFF) * 257,
        green: UInt16((value >> 8) & 0xFF) * 257,
        blue: UInt16(value & 0xFF) * 257)
    }
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
