import Foundation

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

  public init(customThemesDirectory: URL) {
    self.customThemesDirectory = customThemesDirectory
    self.bundledEntries = Self.loadManifest()
    self.customDescriptors = Self.scanCustomThemes(in: customThemesDirectory)
  }

  public var availableThemes: [ThemeDescriptor] {
    Self.systemDescriptors + bundledEntries.map(\.descriptor) + customDescriptors
  }

  public func descriptor(for id: String) -> ThemeDescriptor? {
    availableThemes.first { $0.id == id }
  }

  public nonisolated static func isSystemTheme(id: String) -> Bool {
    id == systemLightID || id == systemDarkID
  }

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

  public func loadTheme(id: String) throws -> VSCodeTheme {
    if let cached = parsedThemes[id] { return cached }
    let theme = try VSCodeTheme.decode(from: loadThemeData(id: id))
    parsedThemes[id] = theme
    return theme
  }

  @discardableResult
  public func importTheme(data: Data, suggestedName: String? = nil) throws -> ThemeDescriptor {
    let theme = try Self.decodeImportableTheme(from: data)

    let baseName = theme.displayName ?? theme.name ?? suggestedName ?? "Custom Theme"
    let slug = uniqueSlug(from: baseName)
    let id = "custom:\(slug)"

    try FileManager.default.createDirectory(
      at: customThemesDirectory, withIntermediateDirectories: true)
    try data.write(
      to: customThemesDirectory.appendingPathComponent("\(slug).json"),
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

  private static func decodeImportableTheme(from data: Data) throws -> VSCodeTheme {
    let theme: VSCodeTheme
    do {
      theme = try VSCodeTheme.decode(from: data)
    } catch {
      themingLog.debug(
        "Imported file failed to decode as a theme: \(String(describing: error), privacy: .public)"
      )
      throw ThemeCatalogError.notATheme
    }
    guard theme.hasColorData else {
      throw ThemeCatalogError.notATheme
    }
    guard PaletteDeriver.derive(from: theme) != nil else {
      throw ThemeCatalogError.noLegibleForeground
    }
    return theme
  }

  public func deleteCustomTheme(id: String) throws {
    guard customDescriptors.contains(where: { $0.id == id }) else {
      throw ThemeCatalogError.unknownTheme(id)
    }
    do {
      try FileManager.default.removeItem(at: customFileURL(for: id))
    } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      themingLog.debug("Custom theme file for \(id, privacy: .public) was already missing")
    } catch {
      themingLog.error(
        "Failed to delete custom theme \(id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      throw error
    }
    customDescriptors.removeAll { $0.id == id }
    parsedThemes.removeValue(forKey: id)
  }

  private static func loadManifest() -> [ManifestEntry] {
    guard
      let url = Bundle.module.url(
        forResource: "manifest", withExtension: "json", subdirectory: "Themes"),
      let data = try? Data(contentsOf: url),
      let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data)
    else {
      themingLog.fault(
        "Bundled theme manifest is missing or malformed — all preset themes unavailable")
      assertionFailure("Bundled theme manifest is missing or malformed")
      return []
    }
    return entries
  }

  private static func scanCustomThemes(in directory: URL) -> [ThemeDescriptor] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return
      files
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        ThemeCatalog.customThemeDescriptor(at: url)
      }
  }

  private static func customThemeDescriptor(at url: URL) -> ThemeDescriptor? {
    let theme: VSCodeTheme
    do {
      theme = try VSCodeTheme.decode(from: try Data(contentsOf: url))
    } catch {
      themingLog.error(
        "Skipped custom theme \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return nil
    }
    guard theme.hasColorData else {
      themingLog.error(
        "Skipped custom theme \(url.lastPathComponent, privacy: .public): no color data"
      )
      return nil
    }
    let slug = url.deletingPathExtension().lastPathComponent
    return ThemeDescriptor(
      id: "custom:\(slug)",
      displayName: theme.displayName ?? theme.name ?? slug,
      type: theme.resolvedIsDark ? .dark : .light,
      group: .custom
    )
  }

  private func customFileURL(for id: String) -> URL {
    let slug = String(id.dropFirst("custom:".count))
    return customThemesDirectory.appendingPathComponent("\(slug).json")
  }

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
