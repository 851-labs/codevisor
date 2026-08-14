import Foundation
import CodevisorTheming
import Testing

@testable import CodevisorCore

@MainActor
@Suite("ThemeManager and theme settings")
struct ThemeManagerTests {
    private func makeManager(
        settings: AppSettingsModel = AppSettingsModel(store: InMemoryStore())
    ) -> ThemeManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-thememanager-tests-\(UUID().uuidString)")
        return ThemeManager(settings: settings, catalog: ThemeCatalog(customThemesDirectory: dir))
    }

    @Test("Defaults are the system themes in system mode")
    func defaults() {
        let manager = makeManager()
        #expect(manager.mode == .system)
        #expect(manager.themeId(for: .light) == ThemeCatalog.systemLightID)
        #expect(manager.themeId(for: .dark) == ThemeCatalog.systemDarkID)
        #expect(manager.palette(for: .light) == nil)
        #expect(manager.palette(for: .dark) == nil)
    }

    @Test("Selection persists through settings")
    func persistence() {
        let store = InMemoryStore()
        let settings = AppSettingsModel(store: store)
        let manager = makeManager(settings: settings)
        manager.setMode(.dark)
        manager.setThemeId("pierre:pierre-dark", for: .dark)
        manager.setThemeId("shiki:github-light", for: .light)

        // A fresh settings model from the same store sees the selection.
        let reloaded = AppSettingsModel(store: store)
        #expect(reloaded.settings.themeMode == .dark)
        #expect(reloaded.settings.darkThemeId == "pierre:pierre-dark")
        #expect(reloaded.settings.lightThemeId == "shiki:github-light")
    }

    @Test("Bundled selection derives a palette and caches it")
    func paletteDerivation() {
        let manager = makeManager()
        manager.setThemeId("pierre:pierre-dark", for: .dark)
        let palette = manager.palette(for: .dark)
        #expect(palette != nil)
        #expect(palette?.isDark == true)
        #expect(manager.palette(forThemeId: "pierre:pierre-dark") == palette)
        #expect(manager.themeData(for: .dark) != nil)
    }

    @Test("Unknown stored ids fall back to system without clobbering")
    func unknownIdFallback() {
        let settings = AppSettingsModel(store: InMemoryStore())
        settings.setDarkThemeId("custom:deleted-long-ago")
        let manager = makeManager(settings: settings)
        #expect(manager.themeId(for: .dark) == ThemeCatalog.systemDarkID)
        #expect(manager.palette(for: .dark) == nil)
        // The stored id is preserved.
        #expect(settings.settings.darkThemeId == "custom:deleted-long-ago")
    }

    @Test("Deleting the active custom theme falls back cleanly")
    func deleteActive() throws {
        let manager = makeManager()
        let json = Data(
            """
            {"name": "Mine", "type": "dark",
             "colors": {"editor.background": "#1e1e2e", "editor.foreground": "#cdd6f4"}}
            """.utf8)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mine-\(UUID().uuidString).json")
        try json.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = try manager.importTheme(from: file)
        #expect(manager.availableThemes.contains(descriptor))
        manager.setThemeId(descriptor.id, for: .dark)
        #expect(manager.palette(for: .dark) != nil)
        try manager.deleteCustomTheme(id: descriptor.id)
        #expect(manager.themeId(for: .dark) == ThemeCatalog.systemDarkID)
        #expect(manager.palette(for: .dark) == nil)
    }

    @Test("Legacy settings JSON decodes with theme defaults")
    func legacyDecode() throws {
        let legacy = Data("{\"hasCompletedOnboarding\": true}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.hasCompletedOnboarding)
        #expect(decoded.shareAnalytics)
        #expect(decoded.themeMode == .system)
        #expect(decoded.lightThemeId == ThemeCatalog.systemLightID)
        #expect(decoded.darkThemeId == ThemeCatalog.systemDarkID)
        #expect(decoded.notificationsEnabled)
        #expect(decoded.systemNotificationsEnabled)
        #expect(decoded.notificationSoundsEnabled)
        #expect(decoded.chatFinishedSoundPath == AppSettings.defaultNotificationSoundPath)
        #expect(decoded.actionRequiredSoundPath == AppSettings.defaultNotificationSoundPath)
    }

    @Test("Pre-onboarding legacy settings remain opted out")
    func preOnboardingLegacyAnalyticsDefault() throws {
        let legacy = Data("{\"hasCompletedOnboarding\": false}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.shareAnalytics == false)
    }
}
