import CryptoKit
import Foundation

public struct ClientStorage: Sendable {
  public let database: ClientDatabase
  public let store: ClientPersistenceStore
  public let launchSnapshot: ClientLaunchSnapshot?

  public init(database: ClientDatabase, store: ClientPersistenceStore, launchSnapshot: ClientLaunchSnapshot? = nil) {
    self.database = database
    self.store = store
    self.launchSnapshot = launchSnapshot
  }
}

public enum ClientStorageBootstrap {
  public static let legacyDataMigrationID = 1
  public static let legacyCleanupMigrationID = 1
  public static let retiredDirectMachinesMigrationID = 2

  private static let legacyDataMigrationName = "legacy file and defaults import"
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

  public static func openAsync(directory: URL) async throws -> ClientStorage {
    let (storage, preferences) = try await Task.detached(priority: .userInitiated) {
      let opened = try openUnconfigured(
        directory: directory,
        legacyDefaults: .standard,
        fileManager: .default,
        migrateRenamedApplicationSupport: true,
        renamedLegacyDirectory: nil
      )
      let storage = ClientStorage(
        database: opened.database,
        store: opened.store,
        launchSnapshot: ClientLaunchSnapshot.read(from: opened.store)
      )
      return (storage, try? opened.database.allPreferences())
    }.value
    await MainActor.run {
      ClientPreferences.shared.configure(database: storage.database, preferences: preferences)
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
      try !LegacyClientArtifacts.cleanupCandidateFiles(
        in: cleanupDirectories,
        fileManager: fileManager
      ).isEmpty
    let legacyPreferencesRemain = !LegacyClientArtifacts.legacyPreferenceKeysPresent(in: legacyDefaults).isEmpty
    if !cleanupIsComplete || legacyFilesRemain || legacyPreferencesRemain {
      try LegacyClientCleanup.run(
        directory: directory,
        legacyDirectories: cleanupDirectories,
        defaults: legacyDefaults,
        database: database,
        fileManager: fileManager
      )
    }

    LegacyClientArtifacts.pruneExpiredRecovery(in: directory, fileManager: fileManager)
    LegacyClientArtifacts.removeRetiredCaches(in: directory, fileManager: fileManager)
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
      try importLegacyContents(
        directories: directories,
        defaults: defaults,
        database: database,
        store: store,
        fileManager: fileManager
      )
    } catch {
      try? database.failDataMigration(
        id: legacyDataMigrationID,
        error: String(describing: error)
      )
      throw error
    }
  }

  private static func importLegacyContents(
    directories: [URL],
    defaults: UserDefaults,
    database: ClientDatabase,
    store: ClientPersistenceStore,
    fileManager: FileManager
  ) throws {
    let files = try LegacyClientArtifacts.legacyFiles(in: directories, fileManager: fileManager)
    let preferences = try LegacyClientArtifacts.legacyPreferences(from: defaults)
    let importedValues = try prepareImportedValues(files: files, store: store)
    try LegacyClientImport.run(
      importedValues: importedValues,
      preferences: preferences,
      database: database,
      store: store
    )
  }

  private static func prepareImportedValues(
    files: [LegacyClientArtifacts.LegacyFile],
    store: ClientPersistenceStore
  ) throws -> [(key: String, data: Data, source: String, digest: String)] {
    var importedValues: [(key: String, data: Data, source: String, digest: String)] = []
    for file in files {
      var data = file.data
      if file.key == "machines" {
        data = try queueRetiredMachines(from: data, store: store)
      }
      importedValues.append((file.key, data, file.url.lastPathComponent, file.digest))
    }
    return importedValues
  }

  private struct RetiredMachineList: Decodable {
    struct Machine: Decodable {
      let id: String
      let name: String?
      let baseURL: URL?
      let token: String?
    }
    let remoteMachines: [Machine]?
  }

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
