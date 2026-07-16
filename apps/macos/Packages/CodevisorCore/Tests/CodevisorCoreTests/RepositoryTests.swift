import Foundation
import Testing
@testable import CodevisorCore

@Suite("Repositories")
struct RepositoryTests {
    @Test("Projects round-trip through the store")
    func projectRoundTrip() {
        let store = InMemoryStore()
        let repository = DefaultProjectRepository(store: store)
        #expect(repository.load().isEmpty)

        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/demo"))
        repository.save([project])
        #expect(repository.load() == [project])
    }

    @Test("Projects migrate from the legacy workspaces cache key")
    func legacyCacheMigration() throws {
        let legacy = Project.fromFolder(URL(fileURLWithPath: "/tmp/old-cache"))
        let store = InMemoryStore()
        try store.saveData(JSONEncoder().encode([legacy]), forKey: "workspaces")

        let repository = DefaultProjectRepository(store: store)
        let migrated = repository.load()
        #expect(migrated == [legacy])
        // Migration persists under the new key so later saves win.
        #expect(store.loadData(forKey: "projects") != nil)
    }

    @Test("Sessions round-trip through the store")
    func sessionRoundTrip() {
        let store = InMemoryStore()
        let repository = DefaultSessionRepository(store: store)
        let session = ChatSession(projectId: UUID(), harnessId: "demo", title: "Chat")
        repository.save([session])
        #expect(repository.load() == [session])
    }

    @Test("Corrupted data decodes as empty")
    func corruptedData() {
        let store = InMemoryStore(storage: ["projects": Data("not json".utf8)])
        let repository = DefaultProjectRepository(store: store)
        #expect(repository.load().isEmpty)
    }

    @Test("Corrupt file is quarantined instead of overwritten")
    func corruptFileQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("projects.json"))

        let store = FileSystemStore(directory: directory)
        let repository = DefaultProjectRepository(store: store)
        #expect(repository.load().isEmpty)

        // The unreadable payload was renamed to a .corrupt-<timestamp> backup
        // so the next save can't destroy the only copy.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.contains("projects.json"))
        #expect(contents.contains { $0.hasPrefix("projects.json.corrupt-") })
    }

    @Test("FileSystemStore persists to a temp directory")
    func fileSystemStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemStore(directory: directory)
        let repository = DefaultSessionRepository(store: store)
        let session = ChatSession(projectId: UUID(), title: "Persisted")
        repository.save([session])
        // Writes land on a background queue (they must not block the main
        // thread in the app); drain before reading through a fresh store.
        store.flushPendingWrites()

        // A fresh store reading the same directory sees the data.
        let reopened = DefaultSessionRepository(store: FileSystemStore(directory: directory))
        #expect(reopened.load() == [session])
    }

    @Test("InMemoryStore reads back written keys")
    func inMemoryStore() throws {
        let store = InMemoryStore()
        #expect(store.loadData(forKey: "missing") == nil)
        try store.saveData(Data([1, 2, 3]), forKey: "k")
        #expect(store.loadData(forKey: "k") == Data([1, 2, 3]))
    }

    @Test("FileSystemStore coalesces saves and removals with the latest operation winning")
    func fileSystemStoreRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSystemStore(directory: directory)

        try store.saveData(Data([1]), forKey: "draft")
        try store.removeData(forKey: "draft")
        #expect(store.loadData(forKey: "draft") == nil)
        store.flushPendingWrites()
        #expect(FileSystemStore(directory: directory).loadData(forKey: "draft") == nil)

        try store.removeData(forKey: "draft")
        try store.saveData(Data([2]), forKey: "draft")
        store.flushPendingWrites()
        #expect(FileSystemStore(directory: directory).loadData(forKey: "draft") == Data([2]))
    }
}
