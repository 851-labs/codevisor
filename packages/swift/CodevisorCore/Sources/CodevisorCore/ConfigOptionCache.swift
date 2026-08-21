import Foundation
import ACPKit

/// A persisted cache of an agent's selectable config options (model, reasoning
/// effort, …) keyed by server and harness id. Enables a stale-while-revalidate flow: the
/// composer shows the last-known options instantly, then the live session
/// refreshes them once the agent connects.
@MainActor
public final class ConfigOptionCache {
    private let store: any PersistenceStore
    private let key: String
    private let capabilitiesKey: String
    private var cache: [String: [String: [SessionConfigOption]]]
    private var capabilitiesCache: [String: [ServerHarnessCapability]]
    /// In-memory generations prevent a capability request started before an
    /// authentication or catalog change from restoring the stale snapshot
    /// after invalidation. They do not need persistence: no request survives
    /// a process launch.
    private var capabilityRevisions: [String: UInt64] = [:]
    /// In-memory catalog-only seeds used to make the first composer render
    /// immediately. They are intentionally not persisted and may be replaced
    /// by the speculative onboarding warm.
    private var provisionalCapabilityServers: Set<String> = []

    public init(store: any PersistenceStore, key: String = "harness-config") {
        self.store = store
        self.key = key
        capabilitiesKey = "\(key)-server-capabilities"
        if let data = store.loadData(forKey: key),
            let decoded = try? JSONDecoder().decode([String: [String: [SessionConfigOption]]].self, from: data)
        {
            cache = decoded
        } else {
            cache = [:]
        }
        if let data = store.loadData(forKey: capabilitiesKey),
            let decoded = try? JSONDecoder().decode([String: [ServerHarnessCapability]].self, from: data)
        {
            capabilitiesCache = decoded
        } else {
            capabilitiesCache = [:]
        }
    }

    /// The cached options for a harness, or an empty list if none are cached.
    public func options(forHarness harnessId: String, onServer serverId: String) -> [SessionConfigOption] {
        cache[serverId]?[harnessId] ?? []
    }

    /// Stores the latest options for a harness and persists them.
    public func store(_ options: [SessionConfigOption], forHarness harnessId: String, onServer serverId: String) {
        cache[serverId, default: [:]][harnessId] = options
        persist()
    }

    public func capabilities(forServer serverId: String) -> [ServerHarnessCapability] {
        capabilitiesCache[serverId] ?? []
    }

    /// Captures the current validity generation for an asynchronous
    /// capability request. Store the result only if this value still matches.
    public func capabilityRevision(forServer serverId: String) -> UInt64 {
        if let revision = capabilityRevisions[serverId] { return revision }
        capabilityRevisions[serverId] = 0
        return 0
    }

    /// Seeds the picker from a harness catalog that is already on screen. The
    /// expensive model/mode inspection can then fill in the rest in the
    /// background without making new chat wait on an empty cache.
    public func seedHarnesses(_ harnesses: [ServerHarness], forServer serverId: String) {
        guard capabilitiesCache[serverId] == nil || provisionalCapabilityServers.contains(serverId) else {
            return
        }
        let capabilities =
            harnesses
            .filter { $0.enabled && $0.isReady }
            .map {
                ServerHarnessCapability(
                    harness: $0,
                    modes: nil,
                    configOptions: [],
                    supportsGoals: nil
                )
            }
        guard !capabilities.isEmpty else { return }
        capabilitiesCache[serverId] = capabilities
        provisionalCapabilityServers.insert(serverId)
    }

    public func needsCapabilityWarm(forServer serverId: String) -> Bool {
        capabilitiesCache[serverId] == nil || provisionalCapabilityServers.contains(serverId)
    }

    public func store(_ capabilities: [ServerHarnessCapability], forServer serverId: String) {
        provisionalCapabilityServers.remove(serverId)
        capabilitiesCache[serverId] = capabilities
        for capability in capabilities {
            cache[serverId, default: [:]][capability.harness.id] = capability.configOptions
        }
        persist()
    }

    /// Stores a capability response only if no catalog mutation invalidated
    /// it while the request was in flight.
    @discardableResult
    public func store(
        _ capabilities: [ServerHarnessCapability],
        forServer serverId: String,
        ifRevision expectedRevision: UInt64
    ) -> Bool {
        guard capabilityRevision(forServer: serverId) == expectedRevision else { return false }
        store(capabilities, forServer: serverId)
        return true
    }

    /// Merges one freshly inspected harness without discarding the cached
    /// catalog for every other harness on the same server.
    public func store(_ capability: ServerHarnessCapability, forServer serverId: String) {
        provisionalCapabilityServers.remove(serverId)
        var capabilities = capabilitiesCache[serverId] ?? []
        if let index = capabilities.firstIndex(where: { $0.harness.id == capability.harness.id }) {
            capabilities[index] = capability
        } else {
            capabilities.append(capability)
        }
        capabilitiesCache[serverId] = capabilities
        cache[serverId, default: [:]][capability.harness.id] = capability.configOptions
        persist()
    }

    /// Merges one capability response only while its request generation is
    /// still current.
    @discardableResult
    public func store(
        _ capability: ServerHarnessCapability,
        forServer serverId: String,
        ifRevision expectedRevision: UInt64
    ) -> Bool {
        guard capabilityRevision(forServer: serverId) == expectedRevision else { return false }
        store(capability, forServer: serverId)
        return true
    }

    /// Stores a speculative warm only while this server has no capability
    /// snapshot. A project-specific composer refresh is more authoritative;
    /// if it wins the race, a generic onboarding warm must not overwrite it.
    @discardableResult
    public func storeIfEmpty(
        _ capabilities: [ServerHarnessCapability],
        forServer serverId: String,
        ifRevision expectedRevision: UInt64? = nil
    ) -> Bool {
        if let expectedRevision,
            capabilityRevision(forServer: serverId) != expectedRevision
        {
            return false
        }
        guard capabilitiesCache[serverId] == nil || provisionalCapabilityServers.contains(serverId) else {
            return false
        }
        store(capabilities, forServer: serverId)
        return true
    }

    /// Drops every capability-derived picker value for one server.
    /// Authentication, account selection, enablement, and discovery can all
    /// change both the harness catalog and each harness's model definitions.
    public func invalidateCapabilities(forServer serverId: String) {
        capabilityRevisions[serverId, default: 0] &+= 1
        cache.removeValue(forKey: serverId)
        capabilitiesCache.removeValue(forKey: serverId)
        provisionalCapabilityServers.remove(serverId)
        persist()
    }

    /// Clears all cached config (used by "Delete all data").
    public func clear() {
        let servers = Set(capabilityRevisions.keys)
            .union(cache.keys)
            .union(capabilitiesCache.keys)
        for serverId in servers {
            capabilityRevisions[serverId, default: 0] &+= 1
        }
        cache = [:]
        capabilitiesCache = [:]
        provisionalCapabilityServers = []
        persist()
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(cache), forKey: key)
        } catch {
            Log.persistence.error(
                "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        do {
            try store.saveData(JSONEncoder().encode(capabilitiesCache), forKey: capabilitiesKey)
        } catch {
            Log.persistence.error(
                "Failed to save \(self.capabilitiesKey, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
