import Foundation
import Testing
@testable import HerdManCore

@Suite("Repositories")
struct RepositoryTests {
    @Test("Workspaces round-trip through the store")
    func workspaceRoundTrip() {
        let store = InMemoryStore()
        let repository = DefaultWorkspaceRepository(store: store)
        #expect(repository.load().isEmpty)

        let workspace = Workspace(name: "Demo", folderURL: URL(fileURLWithPath: "/tmp/demo"))
        repository.save([workspace])
        #expect(repository.load() == [workspace])
    }

    @Test("Sessions round-trip through the store")
    func sessionRoundTrip() {
        let store = InMemoryStore()
        let repository = DefaultSessionRepository(store: store)
        let session = ChatSession(workspaceId: UUID(), harnessId: "demo", title: "Chat")
        repository.save([session])
        #expect(repository.load() == [session])
    }

    @Test("Corrupted data decodes as empty")
    func corruptedData() {
        let store = InMemoryStore(storage: ["workspaces": Data("not json".utf8)])
        let repository = DefaultWorkspaceRepository(store: store)
        #expect(repository.load().isEmpty)
    }

    @Test("FileSystemStore persists to a temp directory")
    func fileSystemStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdman-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemStore(directory: directory)
        let repository = DefaultSessionRepository(store: store)
        let session = ChatSession(workspaceId: UUID(), title: "Persisted")
        repository.save([session])

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
}
