import Foundation

/// Persists the choices the last workspace was created with — project, the
/// starting tab ("mode"), and the worktree toggle — so the New workspace page
/// reopens exactly as it was left (the name is always regenerated). Keyed per
/// machine, file-backed like the rest of the app's stores so it survives app
/// updates.
@MainActor
public final class NewWorkspaceDefaultsStore {
    public struct Defaults: Codable, Equatable, Sendable {
        public var projectId: UUID?
        /// `WorkspaceStartingTab` raw value; stored as a plain string so the
        /// schema doesn't depend on app-target types.
        public var startingTab: String?
        public var newWorktree: Bool

        public init(projectId: UUID? = nil, startingTab: String? = nil, newWorktree: Bool = false) {
            self.projectId = projectId
            self.startingTab = startingTab
            self.newWorktree = newWorktree
        }
    }

    private struct Payload: Codable {
        var version = 1
        var machines: [String: Defaults] = [:]
    }

    private let store: any PersistenceStore
    private let key: String
    private var payload: Payload

    public init(store: any PersistenceStore, key: String = "new-workspace-defaults") {
        self.store = store
        self.key = key
        guard let data = store.loadData(forKey: key) else {
            payload = Payload()
            return
        }
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            payload = Payload()
            handleCorruptPayload(store: store, key: key, data: data, error: error)
        }
    }

    public func defaults(forServer serverId: String) -> Defaults? {
        payload.machines[serverId]
    }

    public func remember(_ defaults: Defaults, forServer serverId: String) {
        payload.machines[serverId] = defaults
        persist()
    }

    /// Clears the remembered defaults (used by "Delete all data").
    public func clear() {
        payload = Payload()
        persist()
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(payload), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
