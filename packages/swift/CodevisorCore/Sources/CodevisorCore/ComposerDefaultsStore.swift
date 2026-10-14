import Foundation

@MainActor
public final class ComposerDefaultsStore {
  nonisolated private static let schemaVersion = 6
  nonisolated private static let legacyServerId = "local"

  public enum Scope: Sendable, Equatable {
    case newWorkspace(serverId: String)

    public var serverId: String {
      switch self {
      case let .newWorkspace(serverId): serverId
      }
    }
  }

  fileprivate struct MachineDefaults: Codable, Sendable {
    var lastHarnessId: String?
    var lastProjectId: UUID?
    var newWorkspaceInWorktree: Bool?
    var configSelections: [String: [String: String]] = [:]
    var worktreeByProject: [String: Bool]?
  }

  private struct Defaults: Codable, Sendable {
    var version = ComposerDefaultsStore.schemaVersion
    var lastNewWorkspaceServerId: String?
    var machines: [String: MachineDefaults] = [:]
  }

  private let store: any PersistenceStore
  private let key: String
  private let migrationBackupKey: String
  private let retiredBackupKeys: [String]
  private let persistenceOwner = UUID()
  private var defaults: Defaults
  private var persistenceBatchDepth = 0
  private var batchNeedsPersistence = false
  private var batchNeedsImmediatePersistence = false

  public init(store: any PersistenceStore, key: String = "composer-defaults") {
    PersistenceEncoding.drain()
    self.store = store
    self.key = key
    migrationBackupKey = "\(key)-pre-v6-backup"
    retiredBackupKeys = [
      "\(key)-pre-v5-backup",
      "\(key)-pre-v4-backup",
      "\(key)-pre-v3-backup",
    ]
    guard let data = store.loadData(forKey: key) else {
      defaults = Defaults()
      return
    }

    let decoder = JSONDecoder()
    if let current = try? decoder.decode(Defaults.self, from: data),
      current.version == Self.schemaVersion
    {
      defaults = current
      return
    }

    if let legacy = Self.decodeLegacyDefaults(data, using: decoder) {
      defaults = legacy
      backupAndPersistMigratedPayload(data)
      return
    }

    defaults = Defaults()
    let error = DecodingError.dataCorrupted(
      .init(codingPath: [], debugDescription: "Unrecognized composer defaults payload")
    )
    handleCorruptPayload(store: store, key: key, data: data, error: error)
  }

  public func lastHarnessId(for scope: Scope) -> String? {
    defaults.machines[scope.serverId]?.lastHarnessId
  }

  public func configSelections(
    forHarness harnessId: String,
    in scope: Scope
  ) -> [String: String] {
    defaults.machines[scope.serverId]?.configSelections[harnessId] ?? [:]
  }

  public func rememberHarnessSelection(serverId: String, harnessId: String?) {
    rememberHarnessSelection(in: .newWorkspace(serverId: serverId), harnessId: harnessId)
  }

  public func rememberHarnessSelection(in scope: Scope, harnessId: String?) {
    guard let harnessId, !harnessId.isEmpty else { return }
    var machine = defaults.machines[scope.serverId] ?? MachineDefaults()
    machine.lastHarnessId = harnessId
    defaults.machines[scope.serverId] = machine
    persist()
  }

  public func lastProjectId(forServer serverId: String) -> UUID? {
    defaults.machines[serverId]?.lastProjectId
  }

  public var lastNewWorkspaceServerId: String? {
    defaults.lastNewWorkspaceServerId
  }

  public func rememberNewWorkspaceServer(serverId: String) {
    defaults.lastNewWorkspaceServerId = serverId
    persist()
  }

  public func rememberNewWorkspaceProject(serverId: String, projectId: UUID) {
    var machine = defaults.machines[serverId] ?? MachineDefaults()
    machine.lastProjectId = projectId
    defaults.machines[serverId] = machine
    defaults.lastNewWorkspaceServerId = serverId
    persist()
  }

  public func prefersWorktreeForNewWorkspaces(forServer serverId: String, projectId: UUID) -> Bool {
    let machine = defaults.machines[serverId]
    return machine?.worktreeByProject?[projectId.uuidString]
      ?? machine?.newWorkspaceInWorktree
      ?? false
  }

  public func rememberNewWorkspaceWorktreePreference(
    serverId: String,
    projectId: UUID,
    createsWorktree: Bool
  ) {
    var machine = defaults.machines[serverId] ?? MachineDefaults()
    var byProject = machine.worktreeByProject ?? [:]
    byProject[projectId.uuidString] = createsWorktree
    machine.worktreeByProject = byProject
    defaults.machines[serverId] = machine
    persist()
  }

  public func rememberConfigSelections(
    in scope: Scope,
    harnessId: String?,
    configValues: [String: String]
  ) {
    guard let harnessId, !harnessId.isEmpty else { return }
    let configValues = configValues.filter { !$0.value.isEmpty }
    guard !configValues.isEmpty else { return }
    var machine = defaults.machines[scope.serverId] ?? MachineDefaults()
    var selections = machine.configSelections[harnessId] ?? [:]
    selections.merge(configValues) { _, latest in latest }
    machine.configSelections[harnessId] = selections
    defaults.machines[scope.serverId] = machine
    persist()
  }

  public func backfillNewWorkspaceDefaults(
    serverId: String,
    projectId: UUID,
    createsWorktree: Bool
  ) {
    var machine = defaults.machines[serverId] ?? MachineDefaults()
    var changed = false
    if machine.lastProjectId == nil {
      machine.lastProjectId = projectId
      changed = true
    }
    if machine.newWorkspaceInWorktree == nil {
      machine.newWorkspaceInWorktree = createsWorktree
      changed = true
    }
    guard changed else { return }
    defaults.machines[serverId] = machine
    persist()
  }

  public func performPersistenceBatch(
    flushImmediately: Bool = false,
    _ updates: () -> Void
  ) {
    persistenceBatchDepth += 1
    if flushImmediately { batchNeedsImmediatePersistence = true }
    defer {
      persistenceBatchDepth -= 1
      if persistenceBatchDepth == 0, batchNeedsPersistence {
        let immediately = batchNeedsImmediatePersistence
        batchNeedsPersistence = false
        batchNeedsImmediatePersistence = false
        persist(immediately: immediately)
      }
    }
    updates()
  }

  public func clear() {
    defaults = Defaults()
    for backupKey in [migrationBackupKey] + retiredBackupKeys {
      do {
        try store.removeData(forKey: backupKey)
      } catch {
        Log.persistence.error(
          "Failed to remove \(backupKey, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
    persist()
  }

  private func backupAndPersistMigratedPayload(_ data: Data) {
    if store.loadData(forKey: migrationBackupKey) == nil {
      do {
        try store.saveData(data, forKey: migrationBackupKey)
      } catch {
        Log.persistence.error(
          "Failed to back up \(self.key, privacy: .public) before migration: \(String(describing: error), privacy: .public)"
        )
      }
    }
    persist(immediately: true)
    PersistenceEncoding.drain()
  }

  public func flushPendingWrites() {
    persist(immediately: true)
    PersistenceEncoding.drain()
  }

  private func persist(immediately: Bool = false) {
    if persistenceBatchDepth > 0 {
      batchNeedsPersistence = true
      batchNeedsImmediatePersistence = batchNeedsImmediatePersistence || immediately
      return
    }
    let snapshot = defaults
    let store = store
    let key = key
    PersistenceEncoding.enqueueLatest(
      owner: persistenceOwner,
      key: key,
      delay: immediately ? 0 : 0.2
    ) {
      do {
        try store.saveData(PersistenceEncoding.encoder.encode(snapshot), forKey: key)
      } catch {
        Log.persistence.error(
          "Failed to save \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
  }

  private static func decodeLegacyDefaults(
    _ data: Data,
    using decoder: JSONDecoder
  ) -> Defaults? {
    decodeV4V5Defaults(data, using: decoder)
      ?? decodeV3Defaults(data, using: decoder)
      ?? decodeV2Defaults(data, using: decoder)
      ?? decodeV1Defaults(data, using: decoder)
  }

  private static func decodeV4V5Defaults(
    _ data: Data,
    using decoder: JSONDecoder
  ) -> Defaults? {
    if let scoped = try? decoder.decode(DefaultsV4V5.self, from: data),
      let version = scoped.version, version == 4 || version == 5
    {
      return Defaults(
        lastNewWorkspaceServerId: scoped.lastNewWorkspaceServerId,
        machines: scoped.machines
      )
    }
    return nil
  }

  private static func decodeV3Defaults(
    _ data: Data,
    using decoder: JSONDecoder
  ) -> Defaults? {
    if let version3 = try? decoder.decode(DefaultsV3.self, from: data),
      version3.version == 3
    {
      return Defaults(
        machines: version3.machines.mapValues { machine in
          MachineDefaults(
            lastHarnessId: machine.lastHarnessId,
            newWorkspaceInWorktree: machine.newWorkspaceInWorktree,
            configSelections: machine.configSelections ?? [:]
          )
        }
      )
    }
    return nil
  }

  private static func decodeV2Defaults(
    _ data: Data,
    using decoder: JSONDecoder
  ) -> Defaults? {
    if let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: data) {
      return Defaults(
        machines: scoped.machines.mapValues { machine in
          MachineDefaults(
            lastHarnessId: machine.lastHarnessId,
            configSelections: machine.configSelections ?? [:]
          )
        }
      )
    }
    return nil
  }

  private static func decodeV1Defaults(
    _ data: Data,
    using decoder: JSONDecoder
  ) -> Defaults? {
    if let flat = try? decoder.decode(FlatDefaultsV1.self, from: data), flat.isRecognized {
      return Defaults(machines: [
        Self.legacyServerId: MachineDefaults(
          lastHarnessId: flat.lastHarnessId,
          configSelections: flat.configSelections ?? [:]
        )
      ])
    }
    return nil
  }

  private struct DefaultsV4V5: Decodable {
    var version: Int?
    var lastNewWorkspaceServerId: String?
    fileprivate var machines: [String: MachineDefaults]
  }

  private struct DefaultsV3: Decodable {
    var version: Int?
    var machines: [String: MachineDefaultsV3]
  }

  private struct MachineDefaultsV3: Decodable {
    var lastHarnessId: String?
    var newWorkspaceInWorktree: Bool?
    var configSelections: [String: [String: String]]?
  }

  private struct ScopedDefaultsV2: Decodable {
    var machines: [String: MachineDefaultsV2]
  }

  private struct MachineDefaultsV2: Decodable {
    var lastHarnessId: String?
    var runInWorktree: Bool?
    var configSelections: [String: [String: String]]?
  }

  private struct FlatDefaultsV1: Decodable {
    var lastHarnessId: String?
    var runInWorktree: Bool?
    var configSelections: [String: [String: String]]?

    var isRecognized: Bool {
      lastHarnessId != nil || runInWorktree != nil || configSelections != nil
    }
  }
}
