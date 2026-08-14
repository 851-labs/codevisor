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

    private static let legacyDataMigrationName = "legacy file and defaults import"
    private static let legacyCleanupMigrationName = "legacy file and defaults cleanup"
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

    @MainActor
    public static func open(
        directory: URL,
        legacyDefaults: UserDefaults = .standard,
        credentials: any MachineCredentialStore = KeychainMachineCredentialStore.shared,
        fileManager: FileManager = .default,
        migrateRenamedApplicationSupport: Bool = true,
        renamedLegacyDirectory: URL? = nil
    ) throws -> ClientStorage {
        let storage = try openUnconfigured(
            directory: directory,
            legacyDefaults: legacyDefaults,
            credentials: credentials,
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
    public static func openAsync(
        directory: URL,
        credentials: any MachineCredentialStore = KeychainMachineCredentialStore.shared
    ) async throws -> ClientStorage {
        let storage = try await Task.detached(priority: .userInitiated) {
            try openUnconfigured(
                directory: directory,
                legacyDefaults: .standard,
                credentials: credentials,
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
        credentials: any MachineCredentialStore,
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
                credentials: credentials,
                database: database,
                store: store,
                fileManager: fileManager
            )
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
        return ClientStorage(
            database: database,
            store: store
        )
    }

    private struct LegacyFile {
        let key: String
        let url: URL
        let data: Data
        let digest: String
    }

    private static func importLegacyState(
        directories: [URL],
        defaults: UserDefaults,
        credentials: any MachineCredentialStore,
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
                if file.key == "machines",
                    var registry = try? JSONDecoder().decode(MachineRegistry.self, from: data)
                {
                    for index in registry.remoteMachines.indices {
                        guard let token = registry.remoteMachines[index].token, !token.isEmpty else {
                            continue
                        }
                        let machineID = registry.remoteMachines[index].id
                        try credentials.saveToken(token, forMachineID: machineID)
                        guard try credentials.token(forMachineID: machineID) == token else {
                            throw ClientDatabaseError(
                                operation: "legacy credential verification",
                                detail: "Credential read-back failed for \(machineID)"
                            )
                        }
                        registry.remoteMachines[index].token = nil
                    }
                    data = try JSONEncoder().encode(registry)
                }
                importedValues.append(
                    (file.key, data, file.url.lastPathComponent, file.digest)
                )
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

    private static func legacyFiles(
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

    private static func legacyKey(forFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let key = String(name.dropLast(".json".count))
        if exactLegacyKeys.contains(key) { return key }
        if key.hasPrefix("server-authority-v1-") { return key }
        if key.hasPrefix("composer-draft-attachment-") { return key }
        return nil
    }

    private static func cleanupCandidateFiles(
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

    private struct LegacyPreference {
        let key: String
        let data: Data
    }

    private static func legacyPreferences(
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

    private static func legacyPreferenceKeysPresent(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in
            stringPreferenceKeys.contains(key)
                || boolPreferenceKeys.contains(key)
                || key == "remoteBrowserRecents"
                || dynamicStringPreferencePrefixes.contains(where: key.hasPrefix)
                || dynamicDataPreferencePrefixes.contains(where: key.hasPrefix)
        }.sorted()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pruneExpiredRecovery(
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
