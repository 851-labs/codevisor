import Foundation

enum LegacyClientImport {
  static func run(
    importedValues: [(key: String, data: Data, source: String, digest: String)],
    preferences: [LegacyClientArtifacts.LegacyPreference],
    database: ClientDatabase,
    store: ClientPersistenceStore
  ) throws {
    try database.withTransaction {
      try writeValues(importedValues: importedValues, database: database, store: store)
      try importPreferences(preferences: preferences, database: database)
    }

    store.flushBlobWrites()
    try validateValues(importedValues: importedValues, store: store)
    try validatePreferences(preferences: preferences, database: database)
    try database.assertHealthy()
    try database.completeDataMigration(id: ClientStorageBootstrap.legacyDataMigrationID)
  }

  private static func writeValues(
    importedValues: [(key: String, data: Data, source: String, digest: String)],
    database: ClientDatabase,
    store: ClientPersistenceStore
  ) throws {
    for value in importedValues {
      try store.saveData(value.data, forKey: value.key)
      try database.recordMigrationArtifact(
        migrationID: ClientStorageBootstrap.legacyDataMigrationID,
        source: value.source,
        digest: value.digest,
        imported: true,
        cleaned: false
      )
    }
  }

  private static func importPreferences(
    preferences: [LegacyClientArtifacts.LegacyPreference],
    database: ClientDatabase
  ) throws {
    for preference in preferences {
      try database.setPreference(preference.data, forKey: preference.key)
      try database.recordMigrationArtifact(
        migrationID: ClientStorageBootstrap.legacyDataMigrationID,
        source: "defaults:\(preference.key)",
        digest: LegacyClientArtifacts.digest(preference.data),
        imported: true,
        cleaned: false
      )
    }
  }

  private static func validateValues(
    importedValues: [(key: String, data: Data, source: String, digest: String)],
    store: ClientPersistenceStore
  ) throws {
    for value in importedValues {
      guard store.loadData(forKey: value.key) == value.data else {
        throw ClientDatabaseError(
          operation: "legacy import validation",
          detail: "Value \(value.key) did not round-trip"
        )
      }
    }
  }

  private static func validatePreferences(
    preferences: [LegacyClientArtifacts.LegacyPreference],
    database: ClientDatabase
  ) throws {
    for preference in preferences {
      guard try database.preference(forKey: preference.key) == preference.data else {
        throw ClientDatabaseError(
          operation: "legacy preference validation",
          detail: "Preference \(preference.key) did not round-trip"
        )
      }
    }
  }
}
