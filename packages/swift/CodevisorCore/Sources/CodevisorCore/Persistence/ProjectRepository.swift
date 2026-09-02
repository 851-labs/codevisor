import Foundation

/// Persists and retrieves the user's projects.
public protocol ProjectRepository: Sendable {
    func load() -> [Project]
    func save(_ projects: [Project])
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
            !legacy.isEmpty
        else { return [] }
        repository.save(legacy)
        // One-time migration: make the new key visible to direct store reads
        // before returning, preserving the old synchronous save semantics.
        PersistenceEncoding.drain()
        return legacy
    }

    public func save(_ projects: [Project]) { repository.save(projects) }
}
