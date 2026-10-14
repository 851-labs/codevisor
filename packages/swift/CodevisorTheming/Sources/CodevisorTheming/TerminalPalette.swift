import Foundation

public struct TerminalPalette: Equatable, Sendable {
  public let background: RGBA
  public let foreground: RGBA
  public let cursorColor: RGBA?
  public let selectionBackground: RGBA?
  public let selectionForeground: RGBA?
  public let ansi: [RGBA?]
}
