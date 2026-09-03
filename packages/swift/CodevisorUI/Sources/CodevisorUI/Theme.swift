import CodevisorTheming
import SwiftUI
#if canImport(AppKit)
  import AppKit
#endif

extension Color {
  /// Bridges a theming-package RGBA into a SwiftUI color.
  public init(rgba: RGBA) {
    self.init(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a)
  }
}

/// The semantic color tokens every view reads via `@Environment(\.theme)`.
///
/// With no palette (the "System Light"/"System Dark" themes) every token
/// resolves to the dynamic Apple color the app used before theming existed —
/// including material vibrancy — so the system themes render pixel-identical
/// to the unthemed app, and unmigrated views/previews (which get the default
/// environment value) always look right. With a derived palette, tokens are
/// concrete theme colors.
public struct Theme: Equatable, Sendable {
  /// The derived palette, or nil to render the stock Apple look.
  public let palette: DerivedPalette?

  public init(palette: DerivedPalette?) {
    self.palette = palette
  }

  public static let system = Theme(palette: nil)

  public var isSystem: Bool { palette == nil }

  // MARK: - Surfaces

  /// Main content/window surface (editor.background).
  public var windowBackground: Color {
    palette.map { Color(rgba: $0.windowBackground) } ?? Color.themeWindowBackground
  }

  /// Full-page content surface. System themes reveal the native window
  /// backdrop; custom themes paint their explicit editor background.
  public var contentBackground: Color {
    isSystem ? .clear : windowBackground
  }

  /// The sidebar surface. System keeps `.regularMaterial` vibrancy; themed
  /// paints the opaque sidebar color (matching the Pierre/web behavior).
  public var sidebarBackground: AnyShapeStyle {
    palette.map { AnyShapeStyle(Color(rgba: $0.sidebarBackground)) }
      ?? AnyShapeStyle(.regularMaterial)
  }

  /// Inline card/panel fill (tool calls, plans, diffs).
  public var cardBackground: AnyShapeStyle {
    palette.map { AnyShapeStyle(Color(rgba: $0.cardBackground)) }
      ?? AnyShapeStyle(.quaternary.opacity(0.4))
  }

  /// Quiet card fill for suggestion rows and similar (system: a whisper of
  /// secondary).
  public var cardQuietBackground: Color {
    palette.map { Color(rgba: $0.cardBackground) } ?? Color.secondary.opacity(0.08)
  }

  public var cardHoverBackground: Color {
    palette.map { Color(rgba: $0.cardHoverBackground) } ?? Color.secondary.opacity(0.12)
  }

  /// The composer/input surface (controlBackgroundColor role).
  public var composerBackground: Color {
    palette.map { Color(rgba: $0.composerBackground) }
      ?? Color.themeControlBackground
  }

  /// The terminal panel surface behind the terminal view. System theme:
  /// CLEAR — the Ghostty surface runs near-zero background opacity and
  /// composites onto the window's live backdrop (wallpaper tinting and
  /// all), so nothing may paint between the surface and the window.
  /// Custom palettes keep their own opaque terminal surface.
  public var terminalBackground: Color {
    palette.map { Color(rgba: $0.terminal.background) } ?? .clear
  }

  /// The shared pane content surface. Today every pane is a terminal, so it
  /// aliases the terminal surface; as more pane types arrive (chat, diffs,
  /// extensions) they adopt this token so a selected pane tab — filled with
  /// exactly this color — fuses with whatever pane it opens into.
  public var paneBackground: Color { terminalBackground }

  /// The pane-group header (tab strip) surface: the content surface nudged
  /// toward the foreground so the selected tab reads as a cutout into the
  /// pane below.
  public var paneHeaderBackground: Color {
    palette.map { Color(rgba: $0.paneHeaderBackground) }
      ?? Color.themeUnderPageBackground
  }

  /// Popover/sheet surface when themed; system popovers keep their material.
  public var popoverBackground: Color {
    palette.map { Color(rgba: $0.popoverBackground) } ?? Color.themeWindowBackground
  }

  // MARK: - Glass (see ThemedSurfaceModifier.swift)

  /// Tint of themed chrome glass over material: strong enough that the theme
  /// clearly reads, thin enough that the backdrop (vibrancy, desktop
  /// tinting) survives. Light themes need more ink to not look washed out.
  public var chromeTintAlpha: Double {
    (palette?.isDark ?? true) ? 0.65 : 0.75
  }

  /// The sidebar palette color, for glass tinting; nil when system.
  public var sidebarTint: Color? { palette.map { Color(rgba: $0.sidebarBackground) } }

  /// The popover palette color, for glass tinting; nil when system.
  public var popoverTint: Color? { palette.map { Color(rgba: $0.popoverBackground) } }

  /// The user message bubble.
  public var bubbleBackground: Color {
    palette.map { Color(rgba: $0.bubbleBackground) } ?? Color.primary.opacity(0.08)
  }

  // MARK: - Text

  public var textPrimary: Color {
    palette.map { Color(rgba: $0.textPrimary) } ?? Color.primary
  }

  public var textSecondary: Color {
    palette.map { Color(rgba: $0.textSecondary) } ?? Color.secondary
  }

  public var textTertiary: Color {
    palette.map { Color(rgba: $0.textTertiary) } ?? Color.themeTertiaryLabel
  }

  // MARK: - Interaction

  /// Sidebar row hover — quieter than selection so the active row reads.
  public var rowHoverBackground: Color {
    palette.map { Color(rgba: $0.rowHoverBackground) } ?? Color.secondary.opacity(0.12)
  }

  public var rowSelectedBackground: Color {
    palette.map { Color(rgba: $0.rowSelectedBackground) } ?? Color.primary.opacity(0.14)
  }

  public var accent: Color {
    palette.map { Color(rgba: $0.accent) } ?? Color.accentColor
  }

  // MARK: - Borders

  public var border: Color {
    palette.map { Color(rgba: $0.border) } ?? Color.themeSeparator
  }

  public var separator: Color {
    palette.map { Color(rgba: $0.separator) } ?? Color.themeSeparator
  }

  // MARK: - Status + diff

  public var statusOK: Color { palette.map { Color(rgba: $0.statusOK) } ?? .green }
  public var statusWarn: Color { palette.map { Color(rgba: $0.statusWarn) } ?? .orange }
  public var statusError: Color { palette.map { Color(rgba: $0.statusError) } ?? .red }

  public var diffAddedFg: Color { palette.map { Color(rgba: $0.diffAddedFg) } ?? .green }
  public var diffRemovedFg: Color { palette.map { Color(rgba: $0.diffRemovedFg) } ?? .red }
  public var diffAddedBg: Color {
    palette.map { Color(rgba: $0.diffAddedBg) } ?? Color.green.opacity(0.12)
  }
  public var diffRemovedBg: Color {
    palette.map { Color(rgba: $0.diffRemovedBg) } ?? Color.red.opacity(0.12)
  }

  /// The surface code renders on (editor.background): the theme's token
  /// colors are designed against exactly this color, so diff/code bodies
  /// paint it behind highlighted text. System themes keep the card fill.
  public var codeBackground: AnyShapeStyle {
    palette.map { AnyShapeStyle(Color(rgba: $0.windowBackground)) }
      ?? AnyShapeStyle(.quaternary.opacity(0.4))
  }

  /// Diff gutter line numbers (pierre's fg-number token).
  public var diffLineNumberFg: Color {
    palette.map { Color(rgba: $0.diffLineNumberFg) } ?? Color.themeTertiaryLabel
  }
}

private struct ThemeKey: EnvironmentKey {
  static let defaultValue = Theme.system
}

extension EnvironmentValues {
  public var theme: Theme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

/// System-role fallback colors for the System themes. AppKit and UIKit expose
/// different dynamic color sets; each platform picks the closest match so the
/// system themes render native on both.
extension Color {
  static var themeWindowBackground: Color {
    #if canImport(AppKit)
      Color(nsColor: .windowBackgroundColor)
    #else
      Color(uiColor: .systemBackground)
    #endif
  }

  static var themeControlBackground: Color {
    #if canImport(AppKit)
      Color(nsColor: .controlBackgroundColor)
    #else
      Color(uiColor: .secondarySystemBackground)
    #endif
  }

  static var themeUnderPageBackground: Color {
    #if canImport(AppKit)
      Color(nsColor: .underPageBackgroundColor)
    #else
      Color(uiColor: .secondarySystemBackground)
    #endif
  }

  static var themeTertiaryLabel: Color {
    #if canImport(AppKit)
      Color(nsColor: .tertiaryLabelColor)
    #else
      Color(uiColor: .tertiaryLabel)
    #endif
  }

  static var themeSeparator: Color {
    #if canImport(AppKit)
      Color(nsColor: .separatorColor)
    #else
      Color(uiColor: .separator)
    #endif
  }
}
