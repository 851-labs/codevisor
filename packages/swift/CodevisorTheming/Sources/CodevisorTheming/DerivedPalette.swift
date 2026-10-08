import Foundation

/// The opinionated app palette derived from a VSCode/Shiki theme. Authored
/// theme keys win wherever the theme provides a usable one (accent, row
/// hover/selection, elevated widget/menu surfaces, status tints — each behind
/// a legibility guard); derivation (fg-mix surfaces, derived muted text,
/// luminance-picked status constants) is the fallback, not the rule. The
/// derivation is adapted from pierre's diffshub app. All colors are concrete
/// sRGB values; only `border` and the diff backgrounds carry alpha.
public struct DerivedPalette: Equatable, Sendable {
  public let isDark: Bool

  // Surfaces
  public let windowBackground: RGBA
  public let sidebarBackground: RGBA
  public let cardBackground: RGBA
  public let cardHoverBackground: RGBA
  /// Fill behind a fenced Markdown code block. A code block draws no border
  /// of its own, so this fill is the only thing separating it from the page
  /// — unlike `cardBackground`, it is guaranteed to differ from
  /// `windowBackground`.
  public let codeBackground: RGBA
  public let cardBorder: RGBA
  public let popoverBackground: RGBA
  public let popoverBorder: RGBA
  public let composerBackground: RGBA
  public let bubbleBackground: RGBA
  /// The pane-group header (tab strip) surface: the pane content color
  /// nudged toward the foreground, so a selected tab filled with the pane
  /// surface reads as a cutout opening into the pane below.
  public let paneHeaderBackground: RGBA

  // Text hierarchy
  public let textPrimary: RGBA
  public let textSecondary: RGBA
  public let textTertiary: RGBA

  // Interaction
  public let rowHoverBackground: RGBA
  public let rowSelectedBackground: RGBA
  public let accent: RGBA
  public let focusRing: RGBA

  // Borders
  public let border: RGBA
  public let borderOpaque: RGBA
  public let separator: RGBA

  // Status + diff
  public let statusOK: RGBA
  public let statusWarn: RGBA
  public let statusError: RGBA
  public let diffAddedFg: RGBA
  public let diffRemovedFg: RGBA
  public let diffAddedBg: RGBA
  public let diffRemovedBg: RGBA
  /// Diff gutter line numbers on the editor surface (pierre's fg-number:
  /// 65% editor fg toward editor bg).
  public let diffLineNumberFg: RGBA

  public let terminal: TerminalPalette
}
