import Foundation

public struct DerivedPalette: Equatable, Sendable {
  public let isDark: Bool

  public let windowBackground: RGBA
  public let sidebarBackground: RGBA
  public let cardBackground: RGBA
  public let cardHoverBackground: RGBA
  public let codeBackground: RGBA
  public let cardBorder: RGBA
  public let popoverBackground: RGBA
  public let popoverBorder: RGBA
  public let composerBackground: RGBA
  public let bubbleBackground: RGBA
  public let paneHeaderBackground: RGBA

  public let textPrimary: RGBA
  public let textSecondary: RGBA
  public let textTertiary: RGBA

  public let rowHoverBackground: RGBA
  public let rowSelectedBackground: RGBA
  public let accent: RGBA
  public let focusRing: RGBA

  public let border: RGBA
  public let borderOpaque: RGBA
  public let separator: RGBA

  public let statusOK: RGBA
  public let statusWarn: RGBA
  public let statusError: RGBA
  public let diffAddedFg: RGBA
  public let diffRemovedFg: RGBA
  public let diffAddedBg: RGBA
  public let diffRemovedBg: RGBA
  public let diffLineNumberFg: RGBA

  public let terminal: TerminalPalette
}
