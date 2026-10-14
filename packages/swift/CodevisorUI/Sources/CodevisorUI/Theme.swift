import CodevisorTheming
import SwiftUI
#if canImport(AppKit)
  import AppKit
#endif

extension Color {
  public init(rgba: RGBA) {
    self.init(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a)
  }
}

#if canImport(AppKit)
  extension NSColor {
    public convenience init(rgba: RGBA) {
      self.init(
        srgbRed: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, alpha: rgba.a)
    }
  }
#endif

public struct Theme: Equatable, Sendable {
  public let palette: DerivedPalette?

  public init(palette: DerivedPalette?) {
    self.palette = palette
  }

  public static let system = Theme(palette: nil)

  public var isSystem: Bool { palette == nil }

  public var windowBackground: Color {
    palette.map { Color(rgba: $0.windowBackground) } ?? Color.themeWindowBackground
  }

  public var contentBackground: Color {
    isSystem ? .clear : windowBackground
  }

  public var sidebarBackground: AnyShapeStyle {
    palette.map { AnyShapeStyle(Color(rgba: $0.sidebarBackground)) }
      ?? AnyShapeStyle(.regularMaterial)
  }

  public var cardBackground: AnyShapeStyle {
    AnyShapeStyle(cardBackgroundColor)
  }

  public var cardBackgroundColor: Color {
    palette.map { Color(rgba: $0.cardBackground) } ?? Color.themeCardBackground
  }

  #if canImport(AppKit)
    public var cardBackgroundNSColor: NSColor {
      palette.map { NSColor(rgba: $0.cardBackground) } ?? .themeCardBackground
    }
  #endif

  public var cardQuietBackground: Color {
    palette.map { Color(rgba: $0.cardBackground) } ?? Color.secondary.opacity(0.08)
  }

  public var cardHoverBackground: Color {
    palette.map { Color(rgba: $0.cardHoverBackground) } ?? Color.secondary.opacity(0.12)
  }

  public var formRowBackground: Color? {
    isSystem ? nil : cardQuietBackground
  }

  public var composerBackground: Color {
    palette.map { Color(rgba: $0.composerBackground) }
      ?? Color.themeControlBackground
  }

  public var terminalBackground: Color {
    palette.map { Color(rgba: $0.terminal.background) } ?? .clear
  }

  public var paneBackground: Color { terminalBackground }

  public var paneHeaderBackground: Color {
    palette.map { Color(rgba: $0.paneHeaderBackground) }
      ?? Color.themeUnderPageBackground
  }

  public var popoverBackground: Color {
    palette.map { Color(rgba: $0.popoverBackground) } ?? Color.themeWindowBackground
  }

  public var chromeTintAlpha: Double {
    (palette?.isDark ?? true) ? 0.65 : 0.75
  }

  public var sidebarTint: Color? { palette.map { Color(rgba: $0.sidebarBackground) } }

  public var popoverTint: Color? { palette.map { Color(rgba: $0.popoverBackground) } }

  public var bubbleBackground: Color {
    palette.map { Color(rgba: $0.bubbleBackground) } ?? Color.primary.opacity(0.08)
  }

  public var textPrimary: Color {
    palette.map { Color(rgba: $0.textPrimary) } ?? Color.primary
  }

  public var textSecondary: Color {
    palette.map { Color(rgba: $0.textSecondary) } ?? Color.secondary
  }

  public var textTertiary: Color {
    palette.map { Color(rgba: $0.textTertiary) } ?? Color.themeTertiaryLabel
  }

  public var rowHoverBackground: Color {
    palette.map { Color(rgba: $0.rowHoverBackground) } ?? Color.secondary.opacity(0.12)
  }

  public var rowSelectedBackground: Color {
    palette.map { Color(rgba: $0.rowSelectedBackground) } ?? Color.primary.opacity(0.14)
  }

  public var accent: Color {
    palette.map { Color(rgba: $0.accent) } ?? Color.accentColor
  }

  public var border: Color {
    palette.map { Color(rgba: $0.border) } ?? Color.themeSeparator
  }

  public var separator: Color {
    palette.map { Color(rgba: $0.separator) } ?? Color.themeSeparator
  }

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

  public var codeBackground: AnyShapeStyle {
    palette.map { AnyShapeStyle(Color(rgba: $0.windowBackground)) }
      ?? AnyShapeStyle(.quaternary.opacity(0.4))
  }

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

  static var themeCardBackground: Color {
    #if canImport(AppKit)
      Color(nsColor: .themeCardBackground)
    #else
      Color(uiColor: .quaternaryLabel).opacity(Theme.systemCardFillOpacity)
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

extension Theme {
  static let systemCardFillOpacity: CGFloat = 0.4
}

#if canImport(AppKit)
  extension NSColor {
    static var themeCardBackground: NSColor {
      NSColor(name: nil) { _ in
        let base = NSColor.quaternaryLabelColor.usingColorSpace(.sRGB) ?? .quaternaryLabelColor
        return base.withAlphaComponent(base.alphaComponent * Theme.systemCardFillOpacity)
      }
    }
  }
#endif
