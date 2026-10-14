#if canImport(AppKit)
  import AppKit
#endif
import Foundation
import CodevisorTheming
import Observation

@MainActor
@Observable
public final class ThemeManager {
  public let catalog: ThemeCatalog
  public private(set) var availableThemes: [ThemeDescriptor]

  private let settings: AppSettingsModel
  @ObservationIgnored private var paletteCache: [String: DerivedPalette?] = [:]

  public init(settings: AppSettingsModel, catalog: ThemeCatalog) {
    self.settings = settings
    self.catalog = catalog
    self.availableThemes = catalog.availableThemes
    _ = palette(forThemeId: settings.settings.lightThemeId)
    _ = palette(forThemeId: settings.settings.darkThemeId)
    applyAppearanceOverride()
  }

  public var mode: ThemeMode { settings.settings.themeMode }

  public func setMode(_ mode: ThemeMode) {
    settings.setThemeMode(mode)
    applyAppearanceOverride()
  }

  public func themeId(for scheme: ThemeDescriptor.SchemeType) -> String {
    let stored: String
    let fallback: String
    switch scheme {
    case .light:
      stored = settings.settings.lightThemeId
      fallback = ThemeCatalog.systemLightID
    case .dark:
      stored = settings.settings.darkThemeId
      fallback = ThemeCatalog.systemDarkID
    }
    guard catalog.descriptor(for: stored) != nil else { return fallback }
    if !ThemeCatalog.isSystemTheme(id: stored), palette(forThemeId: stored) == nil {
      return fallback
    }
    return stored
  }

  public func setThemeId(_ id: String, for scheme: ThemeDescriptor.SchemeType) {
    switch scheme {
    case .light: settings.setLightThemeId(id)
    case .dark: settings.setDarkThemeId(id)
    }
  }

  public func palette(for scheme: ThemeDescriptor.SchemeType) -> DerivedPalette? {
    palette(forThemeId: themeId(for: scheme))
  }

  public func palette(forThemeId id: String) -> DerivedPalette? {
    if ThemeCatalog.isSystemTheme(id: id) { return nil }
    if let cached = paletteCache[id] { return cached }
    var palette: DerivedPalette?
    do {
      palette = PaletteDeriver.derive(from: try catalog.loadTheme(id: id))
    } catch {
      Log.theming.error(
        "Failed to load theme \(id, privacy: .public); falling back to the system look: \(String(describing: error), privacy: .public)"
      )
    }
    paletteCache[id] = palette
    return palette
  }

  @discardableResult
  public func importTheme(from url: URL) throws -> ThemeDescriptor {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    let descriptor = try catalog.importTheme(
      data: data,
      suggestedName: url.deletingPathExtension().lastPathComponent
    )
    availableThemes = catalog.availableThemes
    return descriptor
  }

  public func deleteCustomTheme(id: String) throws {
    try catalog.deleteCustomTheme(id: id)
    paletteCache.removeValue(forKey: id)
    availableThemes = catalog.availableThemes
  }

  public func applyAppearanceOverride() {
    #if canImport(AppKit)
      guard let app = NSApp else { return }
      switch mode {
      case .light: app.appearance = NSAppearance(named: .aqua)
      case .dark: app.appearance = NSAppearance(named: .darkAqua)
      case .system: app.appearance = nil
      }
    #endif
  }

  public static func defaultCustomThemesDirectory() -> URL {
    CodevisorAppVariant.applicationSupportURL()
      .appendingPathComponent("themes", isDirectory: true)
  }
}
