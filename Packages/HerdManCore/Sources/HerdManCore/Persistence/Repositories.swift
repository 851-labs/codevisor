import Foundation

/// Persists and retrieves the user's workspaces.
public protocol WorkspaceRepository: Sendable {
    func load() -> [Workspace]
    func save(_ workspaces: [Workspace])
}

/// Persists and retrieves chat sessions.
public protocol SessionRepository: Sendable {
    func load() -> [ChatSession]
    func save(_ sessions: [ChatSession])
}

/// A `Codable`-array repository backed by a `PersistenceStore`.
public struct CodableRepository<Element: Codable & Sendable>: Sendable {
    private let store: any PersistenceStore
    private let key: String

    public init(store: any PersistenceStore, key: String) {
        self.store = store
        self.key = key
    }

    public func load() -> [Element] {
        guard let data = store.loadData(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Element].self, from: data)) ?? []
    }

    public func save(_ elements: [Element]) {
        guard let data = try? JSONEncoder().encode(elements) else { return }
        try? store.saveData(data, forKey: key)
    }
}

/// File/in-memory backed workspace repository.
public struct DefaultWorkspaceRepository: WorkspaceRepository {
    private let repository: CodableRepository<Workspace>

    public init(store: any PersistenceStore) {
        self.repository = CodableRepository(store: store, key: "workspaces")
    }

    public func load() -> [Workspace] { repository.load() }
    public func save(_ workspaces: [Workspace]) { repository.save(workspaces) }
}

/// File/in-memory backed session repository.
public struct DefaultSessionRepository: SessionRepository {
    private let repository: CodableRepository<ChatSession>

    public init(store: any PersistenceStore) {
        self.repository = CodableRepository(store: store, key: "sessions")
    }

    public func load() -> [ChatSession] { repository.load() }
    public func save(_ sessions: [ChatSession]) { repository.save(sessions) }
}
