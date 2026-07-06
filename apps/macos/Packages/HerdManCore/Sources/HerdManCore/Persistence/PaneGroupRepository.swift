import Foundation

/// Persists and retrieves each session's pane-group state (tabs, selection,
/// visibility, height). Pane identity MUST survive app restarts: the herdman
/// server keeps one live PTY per pane key with no reaping, so stable keys are
/// what let terminals reattach instead of orphaning shells.
public protocol PaneGroupRepository: Sendable {
    func load(sessionId: UUID) -> PaneGroupState?
    func save(_ state: PaneGroupState, sessionId: UUID)
}

/// File/in-memory backed pane-group repository. All sessions' states live
/// under a single "paneGroups" key as a `[sessionUUID: state]` map.
///
/// The decoded map is cached in memory: saves fire on every tab
/// select/toggle/height drag, and re-reading + re-decoding every session's
/// state from disk per save was measurable main-thread work.
public final class DefaultPaneGroupRepository: PaneGroupRepository, @unchecked Sendable {
    private let store: any PersistenceStore
    private let key = "paneGroups"
    private let lock = NSLock()
    private var cache: [String: PaneGroupState]?

    public init(store: any PersistenceStore) {
        self.store = store
    }

    public func load(sessionId: UUID) -> PaneGroupState? {
        loadAll()[sessionId.uuidString]
    }

    public func save(_ state: PaneGroupState, sessionId: UUID) {
        var all = loadAll()
        all[sessionId.uuidString] = state
        lock.withLock { cache = all }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? store.saveData(data, forKey: key)
    }

    private func loadAll() -> [String: PaneGroupState] {
        if let cached = lock.withLock({ cache }) { return cached }
        let loaded: [String: PaneGroupState]
        if let data = store.loadData(forKey: key) {
            loaded = (try? JSONDecoder().decode([String: PaneGroupState].self, from: data)) ?? [:]
        } else {
            loaded = [:]
        }
        lock.withLock { if cache == nil { cache = loaded } }
        return loaded
    }
}
