import Foundation

/// The 16-slot ANSI palette plus core surface colors a terminal needs, derived
/// from a theme's `terminal.*` keys with editor fallbacks. Slots the theme
/// doesn't define stay nil so the terminal keeps its own defaults.
public struct TerminalPalette: Equatable, Sendable {
  public let background: RGBA
  public let foreground: RGBA
  public let cursorColor: RGBA?
  public let selectionBackground: RGBA?
  public let selectionForeground: RGBA?
  /// ANSI colors 0–15 in standard order (black…white, brightBlack…brightWhite).
  public let ansi: [RGBA?]
}
