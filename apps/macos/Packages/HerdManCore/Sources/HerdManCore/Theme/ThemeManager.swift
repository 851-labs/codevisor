import AppKit
import Foundation
import HerdManTheming
import Observation

/// The single source of truth for theming: the mode (light/dark/system), the
/// per-scheme theme selection, the catalog of available themes, and a cache of
/// derived palettes. Selection persists through `AppSettingsModel`; theme
/// files live in the catalog's custom directory.
///
/// Init runs synchronously — settings are already loaded and the two selected
/// palettes are derived before the first SwiftUI body evaluation, so the first
/// paint never flashes the default look.
@MainActor
@Observable
public final class ThemeManager {
    public let catalog: ThemeCatalog
    /// All selectable themes, refreshed on import/delete (the catalog itself
    /// is not observable; this stored copy is what pickers watch).
    public private(set) var availableThemes: [ThemeDescriptor]

    private let settings: AppSettingsModel
    // Caches derivation results per theme id. `nil` palettes (system entries,
    // degenerate themes) are cached too, hence the double optional via `has`.
    @ObservationIgnored private var paletteCache: [String: DerivedPalette?] = [:]

    public init(settings: AppSettingsModel, catalog: ThemeCatalog) {
        self.settings = settings
        self.catalog = catalog
        self.availableThemes = catalog.availableThemes
        // Warm the selected slots so tokens exist before the first paint.
        _ = palette(forThemeId: settings.settings.lightThemeId)
        _ = palette(forThemeId: settings.settings.darkThemeId)
        applyAppearanceOverride()
    }

    // MARK: - Selection

    public var mode: ThemeMode { settings.settings.themeMode }

    public func setMode(_ mode: ThemeMode) {
        settings.setThemeMode(mode)
        applyAppearanceOverride()
    }

    /// The active theme id for a scheme slot. A stored id that no longer
    /// resolves (deleted custom theme, corrupted file) falls back to the
    /// system entry without clobbering the stored value.
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
        // A stored theme that fails to derive is as unusable as a missing one.
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

    /// The derived palette for the active theme of the given scheme, or nil
    /// when that slot is a system theme (render the stock Apple look).
    public func palette(for scheme: ThemeDescriptor.SchemeType) -> DerivedPalette? {
        palette(forThemeId: themeId(for: scheme))
    }

    /// The derived palette for any theme id (nil for system entries and
    /// degenerate themes), cached per id.
    public func palette(forThemeId id: String) -> DerivedPalette? {
        if ThemeCatalog.isSystemTheme(id: id) { return nil }
        if let cached = paletteCache[id] { return cached }
        let palette = (try? catalog.loadTheme(id: id)).flatMap(PaletteDeriver.derive(from:))
        paletteCache[id] = palette
        return palette
    }

    /// The raw theme JSON for the active theme of the given scheme (what the
    /// syntax highlighter consumes); nil for system entries.
    public func themeData(for scheme: ThemeDescriptor.SchemeType) -> Data? {
        let id = themeId(for: scheme)
        guard !ThemeCatalog.isSystemTheme(id: id) else { return nil }
        return try? catalog.loadThemeData(id: id)
    }

    // MARK: - Custom themes

    /// Imports a theme JSON file the user picked. Reads through the security
    /// scope (fileImporter URLs are scoped in the sandbox) and copies the bytes
    /// into the custom themes directory.
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

    /// Deletes an imported theme. A slot pointing at it falls back to the
    /// system default via `themeId(for:)`'s validation on the next read.
    public func deleteCustomTheme(id: String) throws {
        try catalog.deleteCustomTheme(id: id)
        paletteCache.removeValue(forKey: id)
        availableThemes = catalog.availableThemes
    }

    // MARK: - Appearance

    /// Forces the AppKit appearance when the mode is explicit, so native chrome
    /// (menus, alerts, window materials) matches the theme; `.system` restores
    /// OS-following behavior. No-ops when no NSApplication exists (unit tests).
    public func applyAppearanceOverride() {
        guard let app = NSApp else { return }
        switch mode {
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        case .system: app.appearance = nil
        }
    }

    /// The default location for imported theme files:
    /// `Application Support/<variant>/themes`.
    public static func defaultCustomThemesDirectory() -> URL {
        HerdManAppVariant.applicationSupportURL()
            .appendingPathComponent("themes", isDirectory: true)
    }
}
