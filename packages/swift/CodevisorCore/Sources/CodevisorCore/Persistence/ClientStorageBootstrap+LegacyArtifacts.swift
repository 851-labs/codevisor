import CryptoKit
import Foundation

extension ClientStorageBootstrap {
  private static let recoveryRetention: TimeInterval = 30 * 24 * 60 * 60

  private static let exactLegacyKeys: Set<String> = [
    "projects",
    "sessions",
    "workspaces",
    "paneGroups",
    "machines",
    "settings",
    "harness-config",
    "harness-config-server-capabilities",
    "composer-defaults",
    "composer-defaults-pre-v3-backup",
    "composer-defaults-pre-v4-backup",
    "composer-drafts",
    "composer-pane-drafts",
    "pending-server-sessions-v1",
    "pending-archived-sessions-v1",
  ]

  private static let stringPreferenceKeys: Set<String> = [
    "sidebar.organization",
    "sidebar.order",
    "sidebar.manualProjectOrder",
    "sidebar.manualSessionOrder",
    "sidebar.expandedProjects",
    "sidebar.expandedWorkspaces",
    "update.skippedVersion",
    "update.skippedServerVersion",
  ]

  private static let boolPreferenceKeys: Set<String> = [
    "sidebar.collapsed",
    "sidebar.showArchived",
    "sidebar.archivedExpanded",
    "ios.onboarding.dismissed",
  ]

  private static let dynamicStringPreferencePrefixes = [
    "harnessUpdateDismissed.",
    "harnessInstallMethod.",
  ]

  private static let dynamicDataPreferencePrefixes = [
    "ios.workspace.panes."
  ]

  struct LegacyFile {
    let key: String
    let url: URL
    let data: Data
    let digest: String
  }

  static func legacyFiles(
    in directories: [URL],
    fileManager: FileManager
  ) throws -> [LegacyFile] {
    var filesByKey: [String: LegacyFile] = [:]
    for directory in directories where fileManager.fileExists(atPath: directory.path) {
      for url in try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) {
        guard let key = legacyKey(forFileName: url.lastPathComponent) else {
          continue
        }
        let data = try Data(contentsOf: url)
        // Directories are ordered oldest to newest, so current
        // Codevisor state wins over a stale pre-rename copy.
        filesByKey[key] = LegacyFile(
          key: key,
          url: url,
          data: data,
          digest: digest(data)
        )
      }
    }
    return filesByKey.values.sorted { $0.key < $1.key }
  }

  static func legacyKey(forFileName name: String) -> String? {
    guard name.hasSuffix(".json") else { return nil }
    let key = String(name.dropLast(".json".count))
    if exactLegacyKeys.contains(key) { return key }
    if key.hasPrefix("server-authority-v1-") { return key }
    if key.hasPrefix("composer-draft-attachment-") { return key }
    return nil
  }

  static func cleanupCandidateFiles(
    in directories: [URL],
    fileManager: FileManager
  ) throws -> [URL] {
    var candidates: [URL] = []
    for directory in directories where fileManager.fileExists(atPath: directory.path) {
      let contents = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
      candidates.append(
        contentsOf: contents.filter { url in
          let name = url.lastPathComponent
          if legacyKey(forFileName: name) != nil { return true }
          return exactLegacyKeys.contains { name.hasPrefix("\($0).json.corrupt-") }
        })
    }
    return candidates
  }

  struct LegacyPreference {
    let key: String
    let data: Data
  }

  static func legacyPreferences(
    from defaults: UserDefaults
  ) throws -> [LegacyPreference] {
    try legacyPreferenceKeysPresent(in: defaults).compactMap { key in
      if stringPreferenceKeys.contains(key)
        || dynamicStringPreferencePrefixes.contains(where: key.hasPrefix)
      {
        guard let value = defaults.string(forKey: key) else { return nil }
        return LegacyPreference(key: key, data: try JSONEncoder().encode(value))
      }
      if boolPreferenceKeys.contains(key) {
        guard defaults.object(forKey: key) != nil else { return nil }
        return LegacyPreference(
          key: key,
          data: try JSONEncoder().encode(defaults.bool(forKey: key))
        )
      }
      if dynamicDataPreferencePrefixes.contains(where: key.hasPrefix) {
        guard let value = defaults.data(forKey: key) else { return nil }
        return LegacyPreference(key: key, data: try JSONEncoder().encode(value))
      }
      if key == "remoteBrowserRecents",
        let value = defaults.dictionary(forKey: key) as? [String: [String]]
      {
        return LegacyPreference(key: key, data: try JSONEncoder().encode(value))
      }
      return nil
    }
  }

  static func legacyPreferenceKeysPresent(in defaults: UserDefaults) -> [String] {
    defaults.dictionaryRepresentation().keys.filter { key in
      stringPreferenceKeys.contains(key)
        || boolPreferenceKeys.contains(key)
        || key == "remoteBrowserRecents"
        || dynamicStringPreferencePrefixes.contains(where: key.hasPrefix)
        || dynamicDataPreferencePrefixes.contains(where: key.hasPrefix)
    }.sorted()
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func pruneExpiredRecovery(
    in directory: URL,
    fileManager: FileManager
  ) {
    let root = directory.appendingPathComponent("MigrationRecovery", isDirectory: true)
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    let cutoff = Date().addingTimeInterval(-recoveryRetention)
    for child in children {
      guard child.lastPathComponent.hasPrefix("legacy-client-state-"),
        let values = try? child.resourceValues(forKeys: [.contentModificationDateKey]),
        let modified = values.contentModificationDate,
        modified < cutoff
      else { continue }
      try? fileManager.removeItem(at: child)
    }
  }
}
