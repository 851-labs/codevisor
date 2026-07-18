import Foundation

/// Persists and retrieves each session's pane-group states (tabs, selection,
/// visibility, height), one per placement (center group + bottom panel). Pane
/// identity MUST survive app restarts: the codevisor server keeps one live PTY
/// per pane key with no reaping, so stable keys are what let terminals
/// reattach instead of orphaning shells.
public protocol PaneGroupRepository: Sendable {
    func load(sessionId: UUID, placement: PaneGroupPlacement) -> PaneGroupState?
    func save(_ state: PaneGroupState, sessionId: UUID, placement: PaneGroupPlacement)
}

/// File/in-memory backed pane-group repository. All sessions' states live
/// under a single "paneGroups" key as a `[storageKey: state]` map, where the
/// bottom panel keeps the legacy bare-UUID key (states persisted before the
/// center group existed load unchanged) and the center group appends a
/// ":center" suffix.
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

    public func load(sessionId: UUID, placement: PaneGroupPlacement) -> PaneGroupState? {
        loadAll()[Self.storageKey(sessionId: sessionId, placement: placement)]
    }

    public func save(_ state: PaneGroupState, sessionId: UUID, placement: PaneGroupPlacement) {
        var all = loadAll()
        all[Self.storageKey(sessionId: sessionId, placement: placement)] = state
        lock.withLock { cache = all }
        do {
            try store.saveData(JSONEncoder().encode(all), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func storageKey(sessionId: UUID, placement: PaneGroupPlacement) -> String {
        switch placement {
        case .bottom: sessionId.uuidString
        case .center: "\(sessionId.uuidString):center"
        }
    }

    private func loadAll() -> [String: PaneGroupState] {
        if let cached = lock.withLock({ cache }) { return cached }
        let loaded: [String: PaneGroupState]
        if let data = store.loadData(forKey: key) {
            do {
                loaded = try JSONDecoder().decode([String: PaneGroupState].self, from: data)
            } catch {
                // No banner: a lost tab layout is recoverable in place; the
                // quarantined backup and fault log keep it diagnosable.
                handleCorruptPayload(store: store, key: key, data: data, error: error)
                loaded = [:]
            }
        } else {
            loaded = [:]
        }
        lock.withLock { if cache == nil { cache = loaded } }
        return loaded
    }
}
