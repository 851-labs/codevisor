import CodevisorUI
import GhosttyTerminal
import SwiftUI
import UIKit

struct TerminalColors: Equatable {
  let background: UIColor
  let foreground: UIColor
  let isDark: Bool

  init(colorScheme: ColorScheme) {
    let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    background = UIColor.systemGroupedBackground.resolvedColor(with: traits)
    foreground = UIColor.label.resolvedColor(with: traits)
    isDark = colorScheme == .dark
  }

  func ghosttyConfiguration(fontSize: Float) -> TerminalConfiguration {
    TerminalConfiguration { builder in
      builder.withFontSize(fontSize)
      builder.withCustom("keybind", "super+k=unbind")
      builder.withBackground(Self.hex(background))
      builder.withForeground(Self.hex(foreground))
      builder.withCursorColor("cell-foreground")
      builder.withCursorText("cell-background")
      for (index, value) in Self.ghosttyANSI.enumerated() {
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

  static let ghosttyANSI: [UInt32] = [
    0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
    0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
  ]
}
