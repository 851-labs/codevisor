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
    /// Banner title shown when the persisted file fails to decode; nil keeps
    /// corruption log-and-quarantine only.
    private let corruptionTitle: String?

    public init(store: any PersistenceStore, key: String, corruptionTitle: String? = nil) {
        self.store = store
        self.key = key
        self.corruptionTitle = corruptionTitle
    }

    public func load() -> [Element] {
        guard let data = store.loadData(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Element].self, from: data)
        } catch {
            handleCorruptPayload(
                store: store,
                key: key,
                data: data,
                error: error,
                reportTitle: corruptionTitle,
                reportMessage: "The file was unreadable. A backup was saved in Codevisor's data folder."
            )
            return []
        }
    }

    public func save(_ elements: [Element]) {
        do {
            try store.saveData(JSONEncoder().encode(elements), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// File/in-memory backed project repository.
public struct DefaultProjectRepository: ProjectRepository {
    private let store: any PersistenceStore
    private let repository: CodableRepository<Project>

    public init(store: any PersistenceStore) {
        self.store = store
        self.repository = CodableRepository(
            store: store,
            key: "projects",
            corruptionTitle: "Couldn't Read Your Saved Projects"
        )
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
        self.repository = CodableRepository(
            store: store,
            key: "sessions",
            corruptionTitle: "Couldn't Read Your Saved Sessions"
        )
    }

    public func load() -> [ChatSession] { repository.load() }
    public func save(_ sessions: [ChatSession]) { repository.save(sessions) }
}
