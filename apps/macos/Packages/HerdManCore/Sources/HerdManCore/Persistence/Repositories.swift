import Foundation

/// Persists and retrieves the user's projects.
public protocol ProjectRepository: Sendable {
    func load() -> [Project]
    func save(_ projects: [Project])
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

/// File/in-memory backed project repository.
public struct DefaultProjectRepository: ProjectRepository {
    private let store: any PersistenceStore
    private let repository: CodableRepository<Project>

    public init(store: any PersistenceStore) {
        self.store = store
        self.repository = CodableRepository(store: store, key: "projects")
    }

    public func load() -> [Project] {
        let projects = repository.load()
        if !projects.isEmpty { return projects }
        // Migrate the pre-rename cache ("workspaces", single folderURL records)
        // the first time the new key comes up empty. Project's decoder maps the
        // legacy shape onto locations.
        guard let data = store.loadData(forKey: "workspaces"),
              let legacy = try? JSONDecoder().decode([Project].self, from: data),
              !legacy.isEmpty else { return [] }
        repository.save(legacy)
        return legacy
    }

    public func save(_ projects: [Project]) { repository.save(projects) }
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
