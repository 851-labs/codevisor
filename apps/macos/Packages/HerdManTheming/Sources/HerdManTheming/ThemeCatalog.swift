import Foundation

/// Errors surfaced by theme import and lookup, with user-facing messages the
/// settings UI shows directly.
public enum ThemeCatalogError: LocalizedError, Equatable {
    case notATheme
    case noLegibleForeground
    case unknownTheme(String)

    public var errorDescription: String? {
        switch self {
        case .notATheme:
            return "This file isn't a VSCode or Shiki color theme."
        case .noLegibleForeground:
            return "This theme has no legible foreground color and can't style the app."
        case .unknownTheme(let id):
            return "Unknown theme “\(id)”."
        }
    }
}

/// The set of themes the app can offer: the two system entries, the bundled
/// Pierre + Shiki presets (indexed by the committed manifest), and any
/// user-imported themes in the custom directory. Also owns the custom-theme
/// import/delete file operations.
@MainActor
public final class ThemeCatalog {
    public nonisolated static let systemLightID = "system-light"
    public nonisolated static let systemDarkID = "system-dark"

    private static let systemDescriptors = [
        ThemeDescriptor(
            id: systemLightID, displayName: "System Light", type: .light, group: .system),
        ThemeDescriptor(
            id: systemDarkID, displayName: "System Dark", type: .dark, group: .system),
    ]

    // A manifest row: a ThemeDescriptor plus the resource file it loads from.
    private struct ManifestEntry: Codable {
        let id: String
        let file: String
        let displayName: String
        let type: ThemeDescriptor.SchemeType
        let group: ThemeDescriptor.Group

        var descriptor: ThemeDescriptor {
            ThemeDescriptor(id: id, displayName: displayName, type: type, group: group)
        }
    }

    private let customThemesDirectory: URL
    private let bundledEntries: [ManifestEntry]
    private var customDescriptors: [ThemeDescriptor]
    private var parsedThemes: [String: VSCodeTheme] = [:]

    /// - Parameter customThemesDirectory: where imported theme JSONs live
    ///   (created on demand); typically `Application Support/<variant>/themes`.
    public init(customThemesDirectory: URL) {
        self.customThemesDirectory = customThemesDirectory
        self.bundledEntries = Self.loadManifest()
        self.customDescriptors = Self.scanCustomThemes(in: customThemesDirectory)
    }

    /// Every selectable theme in picker order: System, Pierre, Shiki, Custom.
    public var availableThemes: [ThemeDescriptor] {
        Self.systemDescriptors + bundledEntries.map(\.descriptor) + customDescriptors
    }

    /// Selectable themes for one appearance slot.
    public func themes(ofType type: ThemeDescriptor.SchemeType) -> [ThemeDescriptor] {
        availableThemes.filter { $0.type == type }
    }

    public func descriptor(for id: String) -> ThemeDescriptor? {
        availableThemes.first { $0.id == id }
    }

    public nonisolated static func isSystemTheme(id: String) -> Bool {
        id == systemLightID || id == systemDarkID
    }

    /// The raw JSON bytes of a bundled or custom theme (the full document,
    /// including tokenColors — what the syntax highlighter consumes). System
    /// entries have no document and throw.
    public func loadThemeData(id: String) throws -> Data {
        if let entry = bundledEntries.first(where: { $0.id == id }) {
            guard
                let url = Bundle.module.url(
                    forResource: entry.file, withExtension: nil, subdirectory: "Themes")
            else { throw ThemeCatalogError.unknownTheme(id) }
            return try Data(contentsOf: url)
        }
        if customDescriptors.contains(where: { $0.id == id }) {
            return try Data(contentsOf: customFileURL(for: id))
        }
        throw ThemeCatalogError.unknownTheme(id)
    }

    /// The parsed structural theme, cached per id.
    public func loadTheme(id: String) throws -> VSCodeTheme {
        if let cached = parsedThemes[id] { return cached }
        let theme = try VSCodeTheme.decode(from: loadThemeData(id: id))
        parsedThemes[id] = theme
        return theme
    }

    /// Validates and stores a user-supplied theme JSON: it must decode, carry
    /// color data, and derive a legible palette. The original bytes are copied
    /// into the custom directory (never bookmarked — sandbox-safe, and the full
    /// document survives for the highlighter). Returns the new descriptor.
    @discardableResult
    public func importTheme(data: Data, suggestedName: String? = nil) throws -> ThemeDescriptor {
        guard let theme = try? VSCodeTheme.decode(from: data), theme.hasColorData else {
            throw ThemeCatalogError.notATheme
        }
        guard PaletteDeriver.derive(from: theme) != nil else {
            throw ThemeCatalogError.noLegibleForeground
        }

        let baseName = theme.displayName ?? theme.name ?? suggestedName ?? "Custom Theme"
        let slug = uniqueSlug(from: baseName)
        let id = "custom:\(slug)"

        try FileManager.default.createDirectory(
            at: customThemesDirectory, withIntermediateDirectories: true)
        try data.write(to: customThemesDirectory.appendingPathComponent("\(slug).json"),
                       options: .atomic)

        let descriptor = ThemeDescriptor(
            id: id,
            displayName: baseName,
            type: theme.resolvedIsDark ? .dark : .light,
            group: .custom
        )
        customDescriptors.append(descriptor)
        parsedThemes[id] = theme
        return descriptor
    }

    /// Removes an imported theme's file and catalog entry. Bundled and system
    /// themes can't be deleted.
    public func deleteCustomTheme(id: String) throws {
        guard customDescriptors.contains(where: { $0.id == id }) else {
            throw ThemeCatalogError.unknownTheme(id)
        }
        try? FileManager.default.removeItem(at: customFileURL(for: id))
        customDescriptors.removeAll { $0.id == id }
        parsedThemes.removeValue(forKey: id)
    }

    // MARK: - Loading

    private static func loadManifest() -> [ManifestEntry] {
        guard
            let url = Bundle.module.url(
                forResource: "manifest", withExtension: "json", subdirectory: "Themes"),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data)
        else {
            assertionFailure("Bundled theme manifest is missing or malformed")
            return []
        }
        return entries
    }

    // Reads every custom theme JSON eagerly at init: the directory holds a
    // handful of files at most, and descriptors need the parsed type/name.
    // Unreadable or degenerate files are skipped, not deleted.
    private static func scanCustomThemes(in directory: URL) -> [ThemeDescriptor] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard
                    let data = try? Data(contentsOf: url),
                    let theme = try? VSCodeTheme.decode(from: data),
                    theme.hasColorData
                else { return nil }
                let slug = url.deletingPathExtension().lastPathComponent
                return ThemeDescriptor(
                    id: "custom:\(slug)",
                    displayName: theme.displayName ?? theme.name ?? slug,
                    type: theme.resolvedIsDark ? .dark : .light,
                    group: .custom
                )
            }
    }

    private func customFileURL(for id: String) -> URL {
        let slug = String(id.dropFirst("custom:".count))
        return customThemesDirectory.appendingPathComponent("\(slug).json")
    }

    // Kebab-cases a display name and de-dupes against existing custom slugs
    // with a numeric suffix ("my-theme", "my-theme-2", …).
    private func uniqueSlug(from name: String) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char == "-" && result.hasSuffix("-") { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fallback = base.isEmpty ? "custom-theme" : base
        let taken = Set(customDescriptors.map { String($0.id.dropFirst("custom:".count)) })
        if !taken.contains(fallback) { return fallback }
        var counter = 2
        while taken.contains("\(fallback)-\(counter)") { counter += 1 }
        return "\(fallback)-\(counter)"
    }
}
