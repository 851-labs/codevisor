import Foundation
import ACPKit

/// A persisted cache of an agent's selectable config options (model, reasoning
/// effort, …) keyed by harness id. Enables a stale-while-revalidate flow: the
/// composer shows the last-known options instantly, then the live session
/// refreshes them once the agent connects.
@MainActor
public final class ConfigOptionCache {
    private let store: any PersistenceStore
    private let key: String
    private var cache: [String: [SessionConfigOption]]

    public init(store: any PersistenceStore, key: String = "harness-config") {
        self.store = store
        self.key = key
        if let data = store.loadData(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [SessionConfigOption]].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    /// The cached options for a harness, or an empty list if none are cached.
    public func options(forHarness harnessId: String) -> [SessionConfigOption] {
        cache[harnessId] ?? []
    }

    /// Stores the latest options for a harness and persists them.
    public func store(_ options: [SessionConfigOption], forHarness harnessId: String) {
        cache[harnessId] = options
        persist()
    }

    /// Clears all cached config (used by "Delete all data").
    public func clear() {
        cache = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? store.saveData(data, forKey: key)
    }
}
