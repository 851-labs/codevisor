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
    private let capabilitiesKey: String
    private var cache: [String: [SessionConfigOption]]
    private var capabilitiesCache: [String: [ServerHarnessCapability]]

    public init(store: any PersistenceStore, key: String = "harness-config") {
        self.store = store
        self.key = key
        capabilitiesKey = "\(key)-server-capabilities"
        if let data = store.loadData(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [SessionConfigOption]].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
        if let data = store.loadData(forKey: capabilitiesKey),
           let decoded = try? JSONDecoder().decode([String: [ServerHarnessCapability]].self, from: data) {
            capabilitiesCache = decoded
        } else {
            capabilitiesCache = [:]
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

    public func capabilities(forServer serverId: String) -> [ServerHarnessCapability] {
        capabilitiesCache[serverId] ?? []
    }

    public func store(_ capabilities: [ServerHarnessCapability], forServer serverId: String) {
        capabilitiesCache[serverId] = capabilities
        for capability in capabilities {
            cache[capability.harness.id] = capability.configOptions
        }
        persist()
    }

    /// Stores a speculative warm only while this server has no capability
    /// snapshot. A project-specific composer refresh is more authoritative;
    /// if it wins the race, a generic onboarding warm must not overwrite it.
    @discardableResult
    public func storeIfEmpty(_ capabilities: [ServerHarnessCapability], forServer serverId: String) -> Bool {
        guard capabilitiesCache[serverId] == nil else { return false }
        store(capabilities, forServer: serverId)
        return true
    }

    /// Clears all cached config (used by "Delete all data").
    public func clear() {
        cache = [:]
        capabilitiesCache = [:]
        persist()
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(cache), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        do {
            try store.saveData(JSONEncoder().encode(capabilitiesCache), forKey: capabilitiesKey)
        } catch {
            Log.persistence.error("Failed to save \(self.capabilitiesKey, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
