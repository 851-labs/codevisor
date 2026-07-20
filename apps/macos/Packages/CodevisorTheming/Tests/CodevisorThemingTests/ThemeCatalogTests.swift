import Foundation
import Testing

@testable import CodevisorTheming

@MainActor
@Suite("ThemeCatalog")
struct ThemeCatalogTests {
    private func makeCatalog() -> (ThemeCatalog, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-theme-tests-\(UUID().uuidString)")
        return (ThemeCatalog(customThemesDirectory: dir), dir)
    }

    private let validThemeJSON = Data(
        """
        {
          "name": "My Theme",
          "type": "dark",
          "colors": {
            "editor.background": "#1e1e2e",
            "editor.foreground": "#cdd6f4"
          }
        }
        """.utf8)

    @Test("Catalog lists system, pierre, shiki groups in order")
    func catalogOrdering() {
        let (catalog, _) = makeCatalog()
        let themes = catalog.availableThemes
        #expect(themes.count == 46)  // 2 system + 10 pierre + 34 shiki
        #expect(themes[0].id == ThemeCatalog.systemLightID)
        #expect(themes[1].id == ThemeCatalog.systemDarkID)
        let groups = themes.map(\.group)
        // Groups appear in section order with no interleaving.
        #expect(groups == groups.sorted { a, b in
            let order: [ThemeDescriptor.Group] = [.system, .pierre, .shiki, .custom]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        })
        #expect(catalog.themes(ofType: .light).allSatisfy { $0.type == .light })
    }

    @Test("Every bundled theme loads and derives a legible palette")
    func bundledThemesDerive() throws {
        let (catalog, _) = makeCatalog()
        for descriptor in catalog.availableThemes where descriptor.group != .system {
            let theme = try catalog.loadTheme(id: descriptor.id)
            let palette = try #require(
                PaletteDeriver.derive(from: theme),
                "\(descriptor.id) failed to derive")
            let bgL = palette.sidebarBackground.relativeLuminance
            #expect(
                ColorMath.contrastRatio(bgL, palette.textPrimary.relativeLuminance)
                    >= ColorMath.minReadableRatio,
                "\(descriptor.id) primary text below 3:1")
            // Muted text clears 4.5:1, or falls back to the primary foreground
            // on extreme palettes (the documented deriveMutedFg tradeoff).
            #expect(
                ColorMath.contrastRatio(bgL, palette.textSecondary.relativeLuminance)
                    >= ColorMath.minMutedRatio
                    || palette.textSecondary == palette.textPrimary,
                "\(descriptor.id) muted text below 4.5:1 and not the primary fallback")
            #expect(palette.isDark == (descriptor.type == .dark), "\(descriptor.id) type mismatch")
        }
    }

    @Test("Import stores the original bytes and lists the theme")
    func importValid() throws {
        let (catalog, dir) = makeCatalog()
        let descriptor = try catalog.importTheme(data: validThemeJSON)
        #expect(descriptor.id == "custom:my-theme")
        #expect(descriptor.displayName == "My Theme")
        #expect(descriptor.type == .dark)
        #expect(descriptor.group == .custom)
        #expect(catalog.availableThemes.contains(descriptor))
        // Original bytes on disk.
        let stored = try Data(contentsOf: dir.appendingPathComponent("my-theme.json"))
        #expect(stored == validThemeJSON)
        // A fresh catalog re-scans it.
        let rescanned = ThemeCatalog(customThemesDirectory: dir)
        #expect(rescanned.descriptor(for: "custom:my-theme") != nil)
    }

    @Test("Import rejects non-themes and degenerate themes")
    func importInvalid() {
        let (catalog, _) = makeCatalog()
        #expect(throws: ThemeCatalogError.notATheme) {
            try catalog.importTheme(data: Data("{\"foo\": 1}".utf8))
        }
        #expect(throws: (any Error).self) {
            try catalog.importTheme(data: Data("not json".utf8))
        }
        #expect(throws: ThemeCatalogError.noLegibleForeground) {
            try catalog.importTheme(
                data: Data("{\"type\": \"dark\", \"colors\": {\"editor.background\": \"#111\"}}".utf8))
        }
    }

    @Test("Slug de-dupes with numeric suffixes")
    func slugDedupe() throws {
        let (catalog, _) = makeCatalog()
        let first = try catalog.importTheme(data: validThemeJSON)
        let second = try catalog.importTheme(data: validThemeJSON)
        let third = try catalog.importTheme(data: validThemeJSON)
        #expect(first.id == "custom:my-theme")
        #expect(second.id == "custom:my-theme-2")
        #expect(third.id == "custom:my-theme-3")
    }

    @Test("Delete removes the file and the entry")
    func delete() throws {
        let (catalog, dir) = makeCatalog()
        let descriptor = try catalog.importTheme(data: validThemeJSON)
        try catalog.deleteCustomTheme(id: descriptor.id)
        #expect(catalog.descriptor(for: descriptor.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("my-theme.json").path))
        #expect(throws: ThemeCatalogError.unknownTheme(descriptor.id)) {
            try catalog.deleteCustomTheme(id: descriptor.id)
        }
        // Bundled/system entries can't be deleted.
        #expect(throws: ThemeCatalogError.unknownTheme("pierre:pierre-dark")) {
            try catalog.deleteCustomTheme(id: "pierre:pierre-dark")
        }
    }

    @Test("System entries have no theme document")
    func systemEntries() {
        let (catalog, _) = makeCatalog()
        #expect(throws: (any Error).self) {
            try catalog.loadThemeData(id: ThemeCatalog.systemLightID)
        }
        #expect(ThemeCatalog.isSystemTheme(id: ThemeCatalog.systemLightID))
        #expect(!ThemeCatalog.isSystemTheme(id: "pierre:pierre-dark"))
    }
}
