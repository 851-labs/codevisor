import CryptoKit
import Foundation
import Testing
@testable import CodevisorCore

@Suite("Client SQLite persistence", .serialized)
struct ClientDatabaseTests {
    @Test("Schema migrations apply once, are checksummed, and back up upgrades")
    func schemaMigrationFramework() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        let first = ClientSchemaMigration(
            id: 1,
            name: "first",
            sql: "CREATE TABLE first_table (id INTEGER PRIMARY KEY);"
        )
        let second = ClientSchemaMigration(
            id: 2,
            name: "second",
            sql: "CREATE TABLE second_table (id INTEGER PRIMARY KEY);"
        )

        try database.migrate(migrations: [first])
        try database.migrate(migrations: [first])

        let backup = directory.appendingPathComponent("backup/client.sqlite")
        try database.migrate(migrations: [first, second], backupURL: backup)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try database.assertHealthy()

        let editedFirst = ClientSchemaMigration(
            id: 1,
            name: "first",
            sql: "CREATE TABLE first_table (id TEXT PRIMARY KEY);"
        )
        #expect(throws: ClientDatabaseError.self) {
            try database.migrate(migrations: [editedFirst, second])
        }
    }

    @Test("A database newer than the client is rejected")
    func newerSchemaIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        let first = ClientSchemaMigration(
            id: 1,
            name: "first",
            sql: "CREATE TABLE first_table (id INTEGER PRIMARY KEY);"
        )
        let second = ClientSchemaMigration(
            id: 2,
            name: "second",
            sql: "CREATE TABLE second_table (id INTEGER PRIMARY KEY);"
        )
        try database.migrate(migrations: [first, second])

        #expect(throws: ClientDatabaseError.self) {
            try database.migrate(migrations: [first])
        }
    }

    @Test("SQLite store round-trips and quarantines corrupt repository data")
    func storeRoundTripAndQuarantine() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        try database.migrate()
        let store = SQLitePersistenceStore(database: database)

        let session = ChatSession(projectId: UUID(), title: "SQLite")
        let sessions = DefaultSessionRepository(store: store)
        sessions.save([session])
        #expect(sessions.load() == [session])

        try store.saveData(Data("not json".utf8), forKey: "projects")
        #expect(DefaultProjectRepository(store: store).load().isEmpty)
        #expect(store.loadData(forKey: "projects") == nil)
        try database.assertHealthy()
    }

    @Test("Reset clears user rows but preserves migration history")
    func resetPreservesMigrationHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        try database.migrate()
        try database.beginDataMigration(id: 99, name: "test marker")
        try database.completeDataMigration(id: 99)
        try database.setValue(Data("value".utf8), forKey: "projects")
        try database.setPreference(Data("preference".utf8), forKey: "sidebar.order")

        try SQLitePersistenceStore(database: database).resetClientData()

        #expect(try database.value(forKey: "projects") == nil)
        #expect(try database.preference(forKey: "sidebar.order") == nil)
        #expect(try database.dataMigrationState(id: 99) == "completed")
        try database.assertHealthy()
    }

    @Test("Draft attachment bytes use the managed asset directory")
    func attachmentAssets() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        try database.migrate()
        let store = ClientPersistenceStore(database: database, directory: directory)
        let key = "composer-draft-attachment-\(UUID().uuidString.lowercased())"
        let data = Data([0, 1, 2, 3, 255])

        try store.saveData(data, forKey: key)
        store.flushBlobWrites()

        #expect(store.loadData(forKey: key) == data)
        #expect(try database.value(forKey: key) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath:
                    directory
                    .appendingPathComponent("ClientAssets/DraftAttachments/\(key).json")
                    .path
            ))

        try store.resetClientData()
        #expect(store.loadData(forKey: key) == nil)
        try database.assertHealthy()
    }

    @MainActor
    @Test("Legacy files, defaults, and credentials migrate before cleanup")
    func legacyUpgrade() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/legacy-project"))
        let projectsData = try JSONEncoder().encode([project])
        try projectsData.write(to: directory.appendingPathComponent("projects.json"))

        let renamedLegacyDirectory =
            directory
            .deletingLastPathComponent()
            .appendingPathComponent("HerdMan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: renamedLegacyDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: renamedLegacyDirectory) }
        let legacySession = ChatSession(
            projectId: project.id,
            title: "From HerdMan"
        )
        try JSONEncoder().encode([legacySession]).write(
            to: renamedLegacyDirectory.appendingPathComponent("sessions.json")
        )

        let remote = CodevisorMachine(
            id: "remote-example-443",
            name: "Example",
            baseURL: URL(string: "https://example.test")!,
            kind: "remote",
            token: "legacy-secret"
        )
        let registry = MachineRegistry(
            selectedMachineId: remote.id,
            remoteMachines: [remote]
        )
        try JSONEncoder().encode(registry)
            .write(to: directory.appendingPathComponent("machines.json"))

        let attachment = Data([0, 1, 2, 3, 255])
        try attachment.write(
            to: directory.appendingPathComponent(
                "composer-draft-attachment-test.bin.json"
            )
        )

        let suiteName = "ClientDatabaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "sidebar.collapsed")
        defaults.set("grid", forKey: "sidebar.order")
        defaults.set(
            ["remote-example-443": ["/Users/test/Code"]],
            forKey: "remoteBrowserRecents"
        )
        defaults.set(
            Data("pane-state".utf8),
            forKey: "ios.workspace.panes.workspace-1"
        )

        let credentials = InMemoryMachineCredentialStore()
        let storage = try ClientStorageBootstrap.open(
            directory: directory,
            legacyDefaults: defaults,
            credentials: credentials,
            migrateRenamedApplicationSupport: false,
            renamedLegacyDirectory: renamedLegacyDirectory
        )

        #expect(DefaultProjectRepository(store: storage.store).load() == [project])
        #expect(DefaultSessionRepository(store: storage.store).load() == [legacySession])
        #expect(
            storage.store.loadData(
                forKey: "composer-draft-attachment-test.bin"
            ) == attachment
        )
        #expect(
            try storage.database.value(
                forKey: "composer-draft-attachment-test.bin"
            ) == nil
        )
        #expect(try credentials.token(forMachineID: remote.id) == "legacy-secret")

        let persistedRegistry = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(storage.store.loadData(forKey: "machines"))
        )
        #expect(persistedRegistry.remoteMachines.first?.token == nil)
        #expect(
            try storage.database.dataMigrationState(
                id: ClientStorageBootstrap.legacyDataMigrationID
            ) == "completed"
        )
        #expect(
            try storage.database.cleanupMigrationState(
                id: ClientStorageBootstrap.legacyCleanupMigrationID
            ) == "completed"
        )

        #expect(
            decodePreference(
                Bool.self,
                key: "sidebar.collapsed",
                database: storage.database
            ) == true
        )
        #expect(
            decodePreference(
                String.self,
                key: "sidebar.order",
                database: storage.database
            ) == "grid"
        )
        #expect(defaults.object(forKey: "sidebar.collapsed") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("projects.json").path
            ))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("machines.json").path
            ))
        #expect(
            !FileManager.default.fileExists(
                atPath: renamedLegacyDirectory.appendingPathComponent("sessions.json").path
            ))

        let recovery = directory.appendingPathComponent(
            "MigrationRecovery/legacy-client-state-v1"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("projects.json").path
            ))
        let recoveredRegistry = try JSONDecoder().decode(
            MachineRegistry.self,
            from: Data(contentsOf: recovery.appendingPathComponent("machines.json"))
        )
        #expect(recoveredRegistry.remoteMachines.first?.token == nil)

        // A relaunch does not re-import and overwrite current SQLite values.
        let changedProjects = try JSONEncoder().encode([Project]())
        try storage.store.saveData(changedProjects, forKey: "projects")
        let reopened = try ClientStorageBootstrap.open(
            directory: directory,
            legacyDefaults: defaults,
            credentials: credentials,
            migrateRenamedApplicationSupport: false
        )
        #expect(reopened.store.loadData(forKey: "projects") == changedProjects)

        // If an older build recreates state, a later launch preserves it in
        // recovery and removes the live legacy copy without re-importing it.
        try projectsData.write(to: directory.appendingPathComponent("projects.json"))
        defaults.set(false, forKey: "sidebar.collapsed")
        let reopenedAgain = try ClientStorageBootstrap.open(
            directory: directory,
            legacyDefaults: defaults,
            credentials: credentials,
            migrateRenamedApplicationSupport: false
        )
        #expect(reopenedAgain.store.loadData(forKey: "projects") == changedProjects)
        #expect(defaults.object(forKey: "sidebar.collapsed") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("projects.json").path
            ))
    }

    @MainActor
    @Test("A failed cleanup resumes without re-importing or deleting its source")
    func cleanupRetry() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/retry-project"))
        let sourceData = try JSONEncoder().encode([project])
        let source = directory.appendingPathComponent("projects.json")
        try sourceData.write(to: source)

        let recovery = directory.appendingPathComponent(
            "MigrationRecovery/legacy-client-state-v1"
        )
        try FileManager.default.createDirectory(
            at: recovery,
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(
            to: recovery.appendingPathComponent("projects.json")
        )
        let digestPrefix = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        let alternate = recovery.appendingPathComponent(
            "projects.json.reappeared-\(digestPrefix)"
        )
        try Data("collision".utf8).write(to: alternate)

        #expect(throws: ClientDatabaseError.self) {
            _ = try ClientStorageBootstrap.open(
                directory: directory,
                credentials: InMemoryMachineCredentialStore(),
                migrateRenamedApplicationSupport: false
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path))

        let failedDatabase = try ClientDatabase(
            url: directory.appendingPathComponent(ClientDatabase.fileName)
        )
        #expect(
            try failedDatabase.dataMigrationState(
                id: ClientStorageBootstrap.legacyDataMigrationID
            ) == "completed"
        )
        #expect(
            try failedDatabase.cleanupMigrationState(
                id: ClientStorageBootstrap.legacyCleanupMigrationID
            ) == "failed"
        )

        try FileManager.default.removeItem(at: alternate)
        let reopened = try ClientStorageBootstrap.open(
            directory: directory,
            credentials: InMemoryMachineCredentialStore(),
            migrateRenamedApplicationSupport: false
        )

        #expect(DefaultProjectRepository(store: reopened.store).load() == [project])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(
            try reopened.database.cleanupMigrationState(
                id: ClientStorageBootstrap.legacyCleanupMigrationID
            ) == "completed"
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-client-db-\(UUID().uuidString)")
    }

    private func decodePreference<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        database: ClientDatabase
    ) -> Value? {
        guard let data = try? database.preference(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
