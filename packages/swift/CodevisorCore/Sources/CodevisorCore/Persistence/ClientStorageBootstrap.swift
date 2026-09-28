import CryptoKit
import Foundation

public struct ClientStorage: Sendable {
  public let database: ClientDatabase
  public let store: ClientPersistenceStore

  public init(database: ClientDatabase, store: ClientPersistenceStore) {
    self.database = database
    self.store = store
  }
}

/// Opens the client database, upgrades its schema, imports every supported
/// legacy client artifact, validates the result, and only then removes the
/// active legacy copies.
///
/// Both native apps call this before constructing `AppEnvironment`, so no
/// repository or server synchronization task can race the one-time import.
public enum ClientStorageBootstrap {
  public static let legacyDataMigrationID = 1
  public static let legacyCleanupMigrationID = 1
  public static let retiredDirectMachinesMigrationID = 2

  private static let legacyDataMigrationName = "legacy file and defaults import"
  private static let legacyCleanupMigrationName = "legacy file and defaults cleanup"
  private static let retiredDirectMachinesMigrationName = "queue directly paired machines for the cloud account"

  @MainActor
  public static func open(
    directory: URL,
    legacyDefaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    migrateRenamedApplicationSupport: Bool = true,
    renamedLegacyDirectory: URL? = nil
  ) throws -> ClientStorage {
    let storage = try openUnconfigured(
      directory: directory,
      legacyDefaults: legacyDefaults,
      fileManager: fileManager,
      migrateRenamedApplicationSupport: migrateRenamedApplicationSupport,
      renamedLegacyDirectory: renamedLegacyDirectory
    )
    ClientPreferences.shared.configure(database: storage.database)
    return storage
  }

  /// Performs schema and legacy-data migrations away from the main actor so
  /// the native apps can render an explicit whole-window bootstrap state.
  /// Repositories are constructed only after this returns and preferences
  /// are attached back on the main actor, preserving the same no-races
  /// ordering as synchronous `open`.
  public static func openAsync(directory: URL) async throws -> ClientStorage {
    let storage = try await Task.detached(priority: .userInitiated) {
      try openUnconfigured(
        directory: directory,
        legacyDefaults: .standard,
        fileManager: .default,
        migrateRenamedApplicationSupport: true,
        renamedLegacyDirectory: nil
      )
    }.value
    await MainActor.run {
      ClientPreferences.shared.configure(database: storage.database)
    }
    return storage
  }

  private static func openUnconfigured(
    directory: URL,
    legacyDefaults: UserDefaults,
    fileManager: FileManager,
    migrateRenamedApplicationSupport: Bool,
    renamedLegacyDirectory: URL?
  ) throws -> ClientStorage {
    let renamedDirectory =
      renamedLegacyDirectory
      ?? (migrateRenamedApplicationSupport
        ? CodevisorAppVariant.legacyApplicationSupportURL(fileManager: fileManager)
        : nil)
    let importDirectories = [renamedDirectory, directory].compactMap { $0 }
    let cleanupDirectories = [directory, renamedDirectory].compactMap { $0 }
    let databaseURL = directory.appendingPathComponent(ClientDatabase.fileName)
    let database = try ClientDatabase(url: databaseURL, fileManager: fileManager)
    let backupURL =
      directory
      .appendingPathComponent("MigrationRecovery", isDirectory: true)
      .appendingPathComponent("client.sqlite.pre-schema")
    try database.migrate(backupURL: backupURL)
    let store = ClientPersistenceStore(
      database: database,
      directory: directory,
      fileManager: fileManager
    )

    if try database.dataMigrationState(id: legacyDataMigrationID) != "completed" {
      try importLegacyState(
        directories: importDirectories,
        defaults: legacyDefaults,
        database: database,
        store: store,
        fileManager: fileManager
      )
    }

    if try database.dataMigrationState(id: retiredDirectMachinesMigrationID) != "completed" {
      retireDirectMachines(database: database, store: store)
    }

    try database.assertHealthy()

    let cleanupIsComplete =
      try database.cleanupMigrationState(id: legacyCleanupMigrationID) == "completed"
    let legacyFilesRemain =
      try !cleanupCandidateFiles(
        in: cleanupDirectories,
        fileManager: fileManager
      ).isEmpty
    let legacyPreferencesRemain = !legacyPreferenceKeysPresent(in: legacyDefaults).isEmpty
    if !cleanupIsComplete || legacyFilesRemain || legacyPreferencesRemain {
      try cleanupLegacyState(
        directory: directory,
        legacyDirectories: cleanupDirectories,
        defaults: legacyDefaults,
        database: database,
        fileManager: fileManager
      )
    }

    pruneExpiredRecovery(in: directory, fileManager: fileManager)
    removeRetiredCaches(in: directory, fileManager: fileManager)
    return ClientStorage(
      database: database,
      store: store
    )
  }

  private static func importLegacyState(
    directories: [URL],
    defaults: UserDefaults,
    database: ClientDatabase,
    store: ClientPersistenceStore,
    fileManager: FileManager
  ) throws {
    try database.beginDataMigration(
      id: legacyDataMigrationID,
      name: legacyDataMigrationName
    )
    do {
      let files = try legacyFiles(in: directories, fileManager: fileManager)
      let preferences = try legacyPreferences(from: defaults)

      var importedValues: [(key: String, data: Data, source: String, digest: String)] = []
      for file in files {
        var data = file.data
        // The legacy machine list embedded bearer tokens for the retired
        // directly paired machines: queue those machines for the cloud
        // account and keep only the selection, so no token is imported or
        // copied into migration recovery.
        if file.key == "machines" {
          data = try queueRetiredMachines(from: data, store: store)
        }
        importedValues.append((file.key, data, file.url.lastPathComponent, file.digest))
      }

      try database.withTransaction {
        for value in importedValues {
          try store.saveData(value.data, forKey: value.key)
          try database.recordMigrationArtifact(
            migrationID: legacyDataMigrationID,
            source: value.source,
            digest: value.digest,
            imported: true,
            cleaned: false
          )
        }
        for preference in preferences {
          try database.setPreference(preference.data, forKey: preference.key)
          try database.recordMigrationArtifact(
            migrationID: legacyDataMigrationID,
            source: "defaults:\(preference.key)",
            digest: digest(preference.data),
            imported: true,
            cleaned: false
          )
        }
      }

      store.flushBlobWrites()
      for value in importedValues {
        guard store.loadData(forKey: value.key) == value.data else {
          throw ClientDatabaseError(
            operation: "legacy import validation",
            detail: "Value \(value.key) did not round-trip"
          )
        }
      }
      for preference in preferences {
        guard try database.preference(forKey: preference.key) == preference.data else {
          throw ClientDatabaseError(
            operation: "legacy preference validation",
            detail: "Preference \(preference.key) did not round-trip"
          )
        }
      }
      try database.assertHealthy()
      try database.completeDataMigration(id: legacyDataMigrationID)
    } catch {
      try? database.failDataMigration(
        id: legacyDataMigrationID,
        error: String(describing: error)
      )
      throw error
    }
  }

  private static func cleanupLegacyState(
    directory: URL,
    legacyDirectories: [URL],
    defaults: UserDefaults,
    database: ClientDatabase,
    fileManager: FileManager
  ) throws {
    try database.beginCleanupMigration(
      id: legacyCleanupMigrationID,
      name: legacyCleanupMigrationName
    )
    do {
      let recovery =
        directory
        .appendingPathComponent("MigrationRecovery", isDirectory: true)
        .appendingPathComponent("legacy-client-state-v1", isDirectory: true)
      try fileManager.createDirectory(
        at: recovery,
        withIntermediateDirectories: true
      )

      for source in try cleanupCandidateFiles(
        in: legacyDirectories,
        fileManager: fileManager
      ) {
        let destination = recovery.appendingPathComponent(source.lastPathComponent)
        var recoveredURL = destination
        if source.lastPathComponent == "machines.json",
          let sanitized = try database.value(forKey: "machines")
        {
          try sanitized.write(to: destination, options: .atomic)
          try fileManager.removeItem(at: source)
        } else if fileManager.fileExists(atPath: destination.path) {
          let sourceData = try Data(contentsOf: source)
          let destinationData = try Data(contentsOf: destination)
          if sourceData == destinationData {
            try fileManager.removeItem(at: source)
          } else {
            let alternate = recovery.appendingPathComponent(
              "\(source.lastPathComponent).reappeared-\(digest(sourceData).prefix(12))"
            )
            recoveredURL = alternate
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
        } else {
          try fileManager.moveItem(at: source, to: destination)
        }

        try database.recordMigrationArtifact(
          migrationID: legacyDataMigrationID,
          source: source.lastPathComponent,
          digest: digest(try Data(contentsOf: recoveredURL)),
          imported: legacyKey(forFileName: source.lastPathComponent) != nil,
          cleaned: true
        )
      }

      for key in legacyPreferenceKeysPresent(in: defaults) {
        defaults.removeObject(forKey: key)
        try database.recordMigrationArtifact(
          migrationID: legacyDataMigrationID,
          source: "defaults:\(key)",
          digest: "",
          imported: try database.preference(forKey: key) != nil,
          cleaned: true
        )
      }

      try database.completeCleanupMigration(id: legacyCleanupMigrationID)
    } catch {
      try? database.failCleanupMigration(
        id: legacyCleanupMigrationID,
        error: String(describing: error)
      )
      throw error
    }
  }

  /// The persisted shape of a retired directly paired machine. Very old
  /// installs stored its bearer token inline; newer ones keep it in the
  /// Keychain under `id`.
  private struct RetiredMachineList: Decodable {
    struct Machine: Decodable {
      let id: String
      let name: String?
      let baseURL: URL?
      let token: String?
    }
    let remoteMachines: [Machine]?
  }

  /// Queues a persisted machine list's retired directly paired machines for
  /// `DirectMachineCloudAdoption` and returns the list reduced to its
  /// selection. An unreadable list is returned unchanged: the machine list
  /// handles (and quarantines) it on load.
  private static func queueRetiredMachines(from data: Data, store: ClientPersistenceStore) throws -> Data {
    guard let registry = try? JSONDecoder().decode(MachineRegistry.self, from: data) else { return data }
    let retired = (try? JSONDecoder().decode(RetiredMachineList.self, from: data))?.remoteMachines ?? []
    try DirectMachineCloudAdoption.enqueue(
      retired.compactMap { machine in
        guard let baseURL = machine.baseURL else { return nil }
        return PendingDirectMachine(
          id: machine.id,
          name: machine.name ?? baseURL.host() ?? machine.id,
          baseURL: baseURL,
          legacyToken: machine.token.flatMap { $0.isEmpty ? nil : $0 }
        )
      },
      in: store
    )
    return try JSONEncoder().encode(registry.normalized())
  }

  /// Directly paired remote machines were retired: every remote machine now
  /// comes from Codevisor Cloud. Hands them to `DirectMachineCloudAdoption`,
  /// which moves each onto the signed-in account (its Keychain token stays
  /// until then), drops them from the persisted machine list, and forgets the
  /// fleet roster's bookkeeping. An unreadable list must never block launch —
  /// the machine list ignores retired entries anyway. A failure is recorded
  /// and retried on the next launch.
  private static func retireDirectMachines(database: ClientDatabase, store: ClientPersistenceStore) {
    do {
      try database.beginDataMigration(
        id: retiredDirectMachinesMigrationID,
        name: retiredDirectMachinesMigrationName
      )
      if let data = store.loadData(forKey: "machines") {
        try store.saveData(queueRetiredMachines(from: data, store: store), forKey: "machines")
      }
      try store.removeData(forKey: "fleetRoster.applied")
      store.flushBlobWrites()
      try database.completeDataMigration(id: retiredDirectMachinesMigrationID)
    } catch {
      try? database.failDataMigration(
        id: retiredDirectMachinesMigrationID,
        error: String(describing: error)
      )
      Log.persistence.error(
        "Failed to queue directly paired machines: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
