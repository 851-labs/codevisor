import Foundation
import ACPKit

/// A persisted cache of an agent's selectable config options (model, reasoning
/// effort, …) keyed by server and harness id. Enables a stale-while-revalidate flow: the
/// composer shows the last-known options instantly, then background capability
/// inspection refreshes them when the snapshot is stale.
/// Observable: SwiftUI surfaces derive picker content (capabilities, the
/// sign-in-pending list) straight from this cache, so any store on any
/// machine re-renders every mounted consumer — no per-view revision
/// watchers, no controller-held copies to go stale.
@MainActor
@Observable
public final class ConfigOptionCache {
  private struct CapabilityRefreshKey: Hashable {
    let serverId: String
    let cwd: String
  }

  private struct CapabilityRefresh {
    let id: UUID
    let revision: UInt64
    let task: Task<[ServerHarnessCapability], any Error>
  }

  @ObservationIgnored private let store: any PersistenceStore
  @ObservationIgnored private let key: String
  @ObservationIgnored private let capabilitiesKey: String
  private var cache: [String: [String: [SessionConfigOption]]]
  private var capabilitiesCache: [String: [ServerHarnessCapability]]
  /// Fleet-enabled harnesses blocked on sign-in, per server — the
  /// pickers' "sign in required" rows.
  private var signInRequiredCache: [String: [ServerHarness]] = [:]
  /// In-memory generations prevent a capability request started before an
  /// authentication or catalog change from restoring the stale snapshot
  /// after invalidation. They do not need persistence: no request survives
  /// a process launch.
  @ObservationIgnored private var capabilityRevisions: [String: UInt64] = [:]
  /// Capability inspection can launch a temporary CLI process. Share one
  /// request across every draft for the same machine/directory and keep a
  /// short in-memory freshness window so opening tabs is a cache read, not
  /// another process launch.
  @ObservationIgnored private var capabilityRefreshes: [CapabilityRefreshKey: CapabilityRefresh] = [:]
  @ObservationIgnored private var capabilityValidatedAt: [CapabilityRefreshKey: Date] = [:]
  private static let capabilityFreshnessInterval: TimeInterval = 5 * 60
  /// In-memory catalog-only seeds used to make the first composer render
  /// immediately. They are intentionally not persisted and may be replaced
  /// by the speculative onboarding warm.
  @ObservationIgnored private var provisionalCapabilityServers: Set<String> = []

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
    if let data = store.loadData(forKey: "\(key)-sign-in-required"),
      let decoded = try? JSONDecoder().decode([String: [ServerHarness]].self, from: data)
    {
      signInRequiredCache = decoded
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

  /// Fleet-enabled harnesses on this server that are blocked on sign-in.
  public func signInRequired(forServer serverId: String) -> [ServerHarness] {
    signInRequiredCache[serverId] ?? []
  }

  /// Captures the current validity generation for an asynchronous
  /// capability request. Store the result only if this value still matches.
  public func capabilityRevision(forServer serverId: String) -> UInt64 {
    if let revision = capabilityRevisions[serverId] { return revision }
    capabilityRevisions[serverId] = 0
    return 0
  }

  /// Whether the stale snapshot should be revalidated for this project.
  /// Freshness is intentionally process-local: relaunching performs one
  /// live check, while subsequent tabs share that result for a few minutes.
  func needsCapabilityRevalidation(forServer serverId: String, cwd: String) -> Bool {
    let key = CapabilityRefreshKey(serverId: serverId, cwd: cwd)
    guard !capabilities(forServer: serverId).isEmpty,
      let validatedAt = capabilityValidatedAt[key]
    else { return true }
    return Date().timeIntervalSince(validatedAt) >= Self.capabilityFreshnessInterval
  }

  /// Fetches one live capability snapshot per machine/directory at a time.
  /// Empty inspection results retain usable stale picker definitions: the
  /// server uses an empty option list for both "no options" and a best-effort
  /// inspection failure, so replacing a populated snapshot would make an
  /// open picker disappear even though its models may still work.
  func revalidateCapabilities(
    forServer serverId: String,
    cwd: String,
    force: Bool = false,
    fetch: @escaping @Sendable () async throws -> [ServerHarnessCapability]
  ) async throws -> [ServerHarnessCapability]? {
    let key = CapabilityRefreshKey(serverId: serverId, cwd: cwd)
    if !force, !needsCapabilityRevalidation(forServer: serverId, cwd: cwd) {
      return capabilities(forServer: serverId)
    }

    let refresh: CapabilityRefresh
    if let existing = capabilityRefreshes[key] {
      refresh = existing
    } else {
      let created = CapabilityRefresh(
        id: UUID(),
        revision: capabilityRevision(forServer: serverId),
        task: Task { try await fetch() }
      )
      capabilityRefreshes[key] = created
      refresh = created
    }

    do {
      let response = try await refresh.task.value
      guard capabilityRevision(forServer: serverId) == refresh.revision else {
        removeCapabilityRefresh(refresh, for: key)
        return nil
      }
      // The response carries BOTH the usable catalog and the
      // fleet-enabled-but-unauthenticated harnesses (optionless
      // entries); the split lives here so every consumer sees one
      // truth.
      let fetched = response.filter { $0.harness.enabled && $0.harness.isReady }
      signInRequiredCache[serverId] =
        response
        .filter { !$0.harness.enabled && $0.harness.isReady }
        .map(\.harness)
      let merged = preservingUsablePickerData(in: fetched, forServer: serverId)
      store(merged, forServer: serverId)
      // The persisted snapshot is server-wide. A project-specific
      // refresh therefore makes other directories stale rather than
      // pretending their previous validation still describes the newly
      // stored snapshot.
      capabilityValidatedAt = capabilityValidatedAt.filter {
        $0.key.serverId != serverId || $0.key == key
      }
      capabilityValidatedAt[key] = Date()
      removeCapabilityRefresh(refresh, for: key)
      return merged
    } catch {
      removeCapabilityRefresh(refresh, for: key)
      throw error
    }
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

  /// Marks one server's snapshot stale without deleting it. Authentication,
  /// account selection, enablement, and discovery all require a live check,
  /// but mounted composers keep rendering their last usable values until the
  /// replacement arrives.
  public func invalidateCapabilities(forServer serverId: String) {
    capabilityRevisions[serverId, default: 0] &+= 1
    capabilityValidatedAt = capabilityValidatedAt.filter { $0.key.serverId != serverId }
    let matching = capabilityRefreshes.filter { $0.key.serverId == serverId }
    for (key, refresh) in matching {
      refresh.task.cancel()
      capabilityRefreshes[key] = nil
    }
  }

  /// Clears all cached config (used by "Delete all data").
  public func clear() {
    let servers = Set(capabilityRevisions.keys)
      .union(cache.keys)
      .union(capabilitiesCache.keys)
    for serverId in servers {
      capabilityRevisions[serverId, default: 0] &+= 1
    }
    for refresh in capabilityRefreshes.values { refresh.task.cancel() }
    capabilityRefreshes = [:]
    capabilityValidatedAt = [:]
    cache = [:]
    capabilitiesCache = [:]
    signInRequiredCache = [:]
    provisionalCapabilityServers = []
    persist()
  }

  private func removeCapabilityRefresh(
    _ refresh: CapabilityRefresh,
    for key: CapabilityRefreshKey
  ) {
    guard capabilityRefreshes[key]?.id == refresh.id else { return }
    capabilityRefreshes[key] = nil
  }

  private func preservingUsablePickerData(
    in refreshed: [ServerHarnessCapability],
    forServer serverId: String
  ) -> [ServerHarnessCapability] {
    let stale = Dictionary(
      uniqueKeysWithValues: capabilities(forServer: serverId).map { ($0.harness.id, $0) }
    )
    return refreshed.map { capability in
      guard let previous = stale[capability.harness.id] else { return capability }
      var merged = capability
      if merged.configOptions.isEmpty, !previous.configOptions.isEmpty {
        merged.configOptions = previous.configOptions
      }
      if merged.modes == nil { merged.modes = previous.modes }
      if merged.supportsGoals == nil { merged.supportsGoals = previous.supportsGoals }
      return merged
    }
  }

  private func persist() {
    do {
      try store.saveData(JSONEncoder().encode(cache), forKey: key)
    } catch {
      Log.persistence.error(
        "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    try? store.saveData(
      JSONEncoder().encode(signInRequiredCache), forKey: "\(key)-sign-in-required")
    do {
      try store.saveData(JSONEncoder().encode(capabilitiesCache), forKey: capabilitiesKey)
    } catch {
      Log.persistence.error(
        "Failed to save \(self.capabilitiesKey, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}
