import Foundation

enum LegacyClientCleanup {
  private static let legacyCleanupMigrationName = "legacy file and defaults cleanup"

  static func run(
    directory: URL,
    legacyDirectories: [URL],
    defaults: UserDefaults,
    database: ClientDatabase,
    fileManager: FileManager
  ) throws {
    try database.beginCleanupMigration(
      id: ClientStorageBootstrap.legacyCleanupMigrationID,
      name: legacyCleanupMigrationName
    )
    do {
      try recoverFiles(
        directory: directory,
        legacyDirectories: legacyDirectories,
        database: database,
        fileManager: fileManager
      )
      try removeLegacyPreferences(defaults: defaults, database: database)
      try database.completeCleanupMigration(id: ClientStorageBootstrap.legacyCleanupMigrationID)
    } catch {
      try? database.failCleanupMigration(
        id: ClientStorageBootstrap.legacyCleanupMigrationID,
        error: String(describing: error)
      )
      throw error
    }
  }

  private static func recoverFiles(
    directory: URL,
    legacyDirectories: [URL],
    database: ClientDatabase,
    fileManager: FileManager
  ) throws {
    let recovery = try createRecoveryDirectory(directory: directory, fileManager: fileManager)

    for source in try LegacyClientArtifacts.cleanupCandidateFiles(
      in: legacyDirectories,
      fileManager: fileManager
    ) {
      try recoverArtifact(
        source: source,
        recovery: recovery,
        database: database,
        fileManager: fileManager
      )
    }
  }

  private static func createRecoveryDirectory(directory: URL, fileManager: FileManager) throws -> URL {
    let recovery =
      directory
      .appendingPathComponent("MigrationRecovery", isDirectory: true)
      .appendingPathComponent("legacy-client-state-v1", isDirectory: true)
    try fileManager.createDirectory(
      at: recovery,
      withIntermediateDirectories: true
    )

    return recovery
  }

  private static func recoverArtifact(
    source: URL,
    recovery: URL,
    database: ClientDatabase,
    fileManager: FileManager
  ) throws {
    let destination = recovery.appendingPathComponent(source.lastPathComponent)
    var recoveredURL = destination
    try recoverFile(
      source: source,
      destination: destination,
      recovery: recovery,
      recoveredURL: &recoveredURL,
      database: database,
      fileManager: fileManager
    )

    try database.recordMigrationArtifact(
      migrationID: ClientStorageBootstrap.legacyDataMigrationID,
      source: source.lastPathComponent,
      digest: LegacyClientArtifacts.digest(try Data(contentsOf: recoveredURL)),
      imported: LegacyClientArtifacts.legacyKey(forFileName: source.lastPathComponent) != nil,
      cleaned: true
    )
  }

  private static func recoverFile(
    source: URL,
    destination: URL,
    recovery: URL,
    recoveredURL: inout URL,
    database: ClientDatabase,
    fileManager: FileManager
  ) throws {
    if source.lastPathComponent == "machines.json",
      let sanitized = try database.value(forKey: "machines")
    {
      try sanitized.write(to: destination, options: .atomic)
      try fileManager.removeItem(at: source)
    } else if fileManager.fileExists(atPath: destination.path) {
      try recoverExistingFile(
        source: source,
        destination: destination,
        recovery: recovery,
        recoveredURL: &recoveredURL,
        fileManager: fileManager
      )
    } else {
      try fileManager.moveItem(at: source, to: destination)
    }
  }

  private static func recoverExistingFile(
    source: URL,
    destination: URL,
    recovery: URL,
    recoveredURL: inout URL,
    fileManager: FileManager
  ) throws {
    let sourceData = try Data(contentsOf: source)
    let destinationData = try Data(contentsOf: destination)
    if sourceData == destinationData {
      try fileManager.removeItem(at: source)
    } else {
      let alternate = recovery.appendingPathComponent(
        "\(source.lastPathComponent).reappeared-\(LegacyClientArtifacts.digest(sourceData).prefix(12))"
      )
      recoveredURL = alternate
      try recoverAlternateFile(
        source: source,
        alternate: alternate,
        sourceData: sourceData,
        fileManager: fileManager
      )
    }
  }

  private static func recoverAlternateFile(
    source: URL,
    alternate: URL,
    sourceData: Data,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: alternate.path) {
      guard try Data(contentsOf: alternate) == sourceData else {
        throw ClientDatabaseError(
          operation: "legacy cleanup",
          detail: "Recovery artifact collision for \(source.lastPathComponent)"
        )
      }
      try fileManager.removeItem(at: source)
    } else {
      try fileManager.moveItem(at: source, to: alternate)
    }
  }

  private static func removeLegacyPreferences(defaults: UserDefaults, database: ClientDatabase) throws {
    for key in LegacyClientArtifacts.legacyPreferenceKeysPresent(in: defaults) {
      defaults.removeObject(forKey: key)
      try database.recordMigrationArtifact(
        migrationID: ClientStorageBootstrap.legacyDataMigrationID,
        source: "defaults:\(key)",
        digest: "",
        imported: try database.preference(forKey: key) != nil,
        cleaned: true
      )
    }
  }
}
