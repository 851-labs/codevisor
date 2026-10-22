import Foundation
import ACPKit

@MainActor
@Observable
public final class ConfigOptionCache {
  private struct CapabilityRefreshKey: Hashable {
    let serverId: String
    let cwd: String
  }

  private struct HarnessSkillsKey: Hashable {
    let serverId: String
    let cwd: String
    let harnessId: String
  }

  public struct CodevisorSkillsScope: Hashable, Sendable {
    public let serverId: String
    public let projectId: UUID?
    public let sessionId: UUID?

    public init(serverId: String, projectId: UUID?, sessionId: UUID?) {
      self.serverId = serverId
      self.projectId = projectId
      self.sessionId = sessionId
    }
  }

  private typealias CodevisorSkillsRefresh = (id: UUID, task: Task<Void, Never>)

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
  private var signInRequiredCache: [String: [ServerHarness]] = [:]
  @ObservationIgnored private var capabilityRevisions: [String: UInt64] = [:]
  @ObservationIgnored private var capabilityRefreshes: [CapabilityRefreshKey: CapabilityRefresh] = [:]
  @ObservationIgnored private var capabilityValidatedAt: [CapabilityRefreshKey: Date] = [:]
  private static let capabilityFreshnessInterval: TimeInterval = 5 * 60
  private var harnessSkillsCache: [HarnessSkillsKey: SessionSkills] = [:]
  private var codevisorSkillsCache: [CodevisorSkillsScope: [ServerComposerSkill]] = [:]
  @ObservationIgnored private var codevisorSkillRefreshes: [CodevisorSkillsScope: CodevisorSkillsRefresh] = [:]

  struct Persisted: Sendable {
    var options: [String: [String: [SessionConfigOption]]] = [:]
    var capabilities: [String: [ServerHarnessCapability]] = [:]
    var signInRequired: [String: [ServerHarness]] = [:]
  }

  @ObservationIgnored private let persistenceOwner = UUID()

  public nonisolated static let defaultKey = "harness-config"

  public convenience init(store: any PersistenceStore, key: String = ConfigOptionCache.defaultKey) {
    self.init(store: store, key: key, persisted: Self.loadPersisted(from: store, key: key))
  }

  public convenience init(store: any PersistenceStore, launchSnapshot: ClientLaunchSnapshot?) {
    guard let launchSnapshot else {
      self.init(store: store)
      return
    }
    self.init(store: store, key: Self.defaultKey, persisted: launchSnapshot.configOptions)
  }

  private init(store: any PersistenceStore, key: String, persisted: Persisted) {
    self.store = store
    self.key = key
    capabilitiesKey = Self.capabilitiesKey(for: key)
    cache = persisted.options
    capabilitiesCache = persisted.capabilities
    signInRequiredCache = persisted.signInRequired
  }

  private nonisolated static func capabilitiesKey(for key: String) -> String { "\(key)-server-capabilities" }
  private nonisolated static func signInRequiredKey(for key: String) -> String { "\(key)-sign-in-required" }

  nonisolated static func loadPersisted(from store: any PersistenceStore, key: String = defaultKey) -> Persisted {
    let decoder = JSONDecoder()
    var persisted = Persisted()
    if let data = store.loadData(forKey: key),
      let decoded = try? decoder.decode([String: [String: [SessionConfigOption]]].self, from: data)
    {
      persisted.options = decoded
    }
    if let data = store.loadData(forKey: capabilitiesKey(for: key)),
      let decoded = try? decoder.decode([String: [ServerHarnessCapability]].self, from: data)
    {
      persisted.capabilities = decoded
    }
    if let data = store.loadData(forKey: signInRequiredKey(for: key)),
      let decoded = try? decoder.decode([String: [ServerHarness]].self, from: data)
    {
      persisted.signInRequired = decoded
    }
    return persisted
  }

  public func options(forHarness harnessId: String, onServer serverId: String) -> [SessionConfigOption] {
    cache[serverId]?[harnessId] ?? []
  }

  public func store(_ options: [SessionConfigOption], forHarness harnessId: String, onServer serverId: String) {
    cache[serverId, default: [:]][harnessId] = options
    persist()
  }

  public func capabilities(forServer serverId: String) -> [ServerHarnessCapability] {
    capabilitiesCache[serverId] ?? []
  }

  public func signInRequired(forServer serverId: String) -> [ServerHarness] {
    signInRequiredCache[serverId] ?? []
  }

  public func capabilityRevision(forServer serverId: String) -> UInt64 {
    if let revision = capabilityRevisions[serverId] { return revision }
    capabilityRevisions[serverId] = 0
    return 0
  }

  func needsCapabilityRevalidation(forServer serverId: String, cwd: String) -> Bool {
    let key = CapabilityRefreshKey(serverId: serverId, cwd: cwd)
    guard !capabilities(forServer: serverId).isEmpty,
      let validatedAt = capabilityValidatedAt[key]
    else { return true }
    return Date().timeIntervalSince(validatedAt) >= Self.capabilityFreshnessInterval
  }

  public func warmCapabilities(forServer serverId: String, client: any CodevisorServerClienting) async throws {
    _ = try await revalidateCapabilities(forServer: serverId, cwd: "") {
      try await client.capabilities(cwd: "").harnesses
    }
  }

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

    let refresh = capabilityRefresh(for: key, serverId: serverId, fetch: fetch)

    do {
      let response = try await refresh.task.value
      guard capabilityRevision(forServer: serverId) == refresh.revision else {
        removeCapabilityRefresh(refresh, for: key)
        return nil
      }
      let merged = storeCapabilityResponse(response, forServer: serverId)
      storeSkills(from: response, forServer: serverId, cwd: cwd)
      recordCapabilityValidation(for: key, serverId: serverId)
      removeCapabilityRefresh(refresh, for: key)
      return merged
    } catch {
      removeCapabilityRefresh(refresh, for: key)
      throw error
    }
  }

  private func capabilityRefresh(
    for key: CapabilityRefreshKey,
    serverId: String,
    fetch: @escaping @Sendable () async throws -> [ServerHarnessCapability]
  ) -> CapabilityRefresh {
    if let existing = capabilityRefreshes[key] {
      return existing
    } else {
      let created = CapabilityRefresh(
        id: UUID(),
        revision: capabilityRevision(forServer: serverId),
        task: Task { try await fetch() }
      )
      capabilityRefreshes[key] = created
      return created
    }
  }

  private func storeCapabilityResponse(
    _ response: [ServerHarnessCapability],
    forServer serverId: String
  ) -> [ServerHarnessCapability] {
    let fetched = response.filter { $0.harness.enabled && $0.harness.isReady }
    signInRequiredCache[serverId] =
      response
      .filter { !$0.harness.enabled && $0.harness.isReady }
      .map(\.harness)
    let merged = preservingUsablePickerData(in: fetched, forServer: serverId)
    store(merged, forServer: serverId)
    return merged
  }

  private func recordCapabilityValidation(for key: CapabilityRefreshKey, serverId: String) {
    capabilityValidatedAt = capabilityValidatedAt.filter {
      $0.key.serverId != serverId || $0.key == key
    }
    capabilityValidatedAt[key] = Date()
  }

  public func needsCapabilityWarm(forServer serverId: String) -> Bool {
    capabilitiesCache[serverId] == nil
  }

  public func store(_ capabilities: [ServerHarnessCapability], forServer serverId: String) {
    capabilitiesCache[serverId] = capabilities.map(Self.withoutSkills)
    for capability in capabilities {
      cache[serverId, default: [:]][capability.harness.id] = capability.configOptions
    }
    persist()
  }

  public func store(_ capability: ServerHarnessCapability, forServer serverId: String) {
    var capabilities = capabilitiesCache[serverId] ?? []
    let capability = Self.withoutSkills(capability)
    if let index = capabilities.firstIndex(where: { $0.harness.id == capability.harness.id }) {
      capabilities[index] = capability
    } else {
      capabilities.append(capability)
    }
    capabilitiesCache[serverId] = capabilities
    cache[serverId, default: [:]][capability.harness.id] = capability.configOptions
    persist()
  }

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
    guard capabilitiesCache[serverId] == nil else { return false }
    store(capabilities, forServer: serverId)
    return true
  }

  public func invalidateCapabilities(forServer serverId: String) {
    capabilityRevisions[serverId, default: 0] &+= 1
    capabilityValidatedAt = capabilityValidatedAt.filter { $0.key.serverId != serverId }
    let matching = capabilityRefreshes.filter { $0.key.serverId == serverId }
    for (key, refresh) in matching {
      refresh.task.cancel()
      capabilityRefreshes[key] = nil
    }
  }

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
    harnessSkillsCache = [:]
    codevisorSkillsCache = [:]
    for refresh in codevisorSkillRefreshes.values { refresh.task.cancel() }
    codevisorSkillRefreshes = [:]
    persist()
  }

  public func skills(forHarness harnessId: String, onServer serverId: String, cwd: String) -> SessionSkills? {
    harnessSkillsCache[HarnessSkillsKey(serverId: serverId, cwd: cwd, harnessId: harnessId)]
  }

  func storeSkills(from capabilities: [ServerHarnessCapability], forServer serverId: String, cwd: String) {
    for capability in capabilities {
      guard let skills = capability.skills else { continue }
      harnessSkillsCache[HarnessSkillsKey(serverId: serverId, cwd: cwd, harnessId: capability.harness.id)] = skills
    }
  }

  public func codevisorSkills(for scope: CodevisorSkillsScope) -> [ServerComposerSkill] {
    codevisorSkillsCache[scope]
      ?? codevisorSkillsCache[
        CodevisorSkillsScope(serverId: scope.serverId, projectId: scope.projectId, sessionId: nil)
      ] ?? []
  }

  @discardableResult
  func refreshCodevisorSkills(
    for scope: CodevisorSkillsScope,
    fetch: @escaping @Sendable () async throws -> [ServerComposerSkill]
  ) -> Task<Void, Never> {
    if let existing = codevisorSkillRefreshes[scope] { return existing.task }
    let id = UUID()
    let task = Task {
      defer {
        if codevisorSkillRefreshes[scope]?.id == id { codevisorSkillRefreshes[scope] = nil }
      }
      do {
        let skills = try await fetch()
        guard !Task.isCancelled else { return }
        codevisorSkillsCache[scope] = skills
      } catch {
        Log.session.debug(
          "codevisor skills fetch failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
    codevisorSkillRefreshes[scope] = (id, task)
    return task
  }

  private static func withoutSkills(_ capability: ServerHarnessCapability) -> ServerHarnessCapability {
    var stripped = capability
    stripped.skills = nil
    return stripped
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
      if merged.supportsSteering == nil { merged.supportsSteering = previous.supportsSteering }
      return merged
    }
  }

  private func persist() {
    let store = store
    let key = key
    let capabilitiesKey = capabilitiesKey
    let signInRequiredKey = Self.signInRequiredKey(for: key)
    let options = cache
    let capabilities = capabilitiesCache
    let signInRequired = signInRequiredCache
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: key) {
      let encoder = PersistenceEncoding.encoder
      do {
        try store.saveData(encoder.encode(options), forKey: key)
      } catch {
        Log.persistence.error(
          "Failed to save \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      }
      try? store.saveData(encoder.encode(signInRequired), forKey: signInRequiredKey)
      do {
        try store.saveData(encoder.encode(capabilities), forKey: capabilitiesKey)
      } catch {
        Log.persistence.error(
          "Failed to save \(capabilitiesKey, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }
  }
}
