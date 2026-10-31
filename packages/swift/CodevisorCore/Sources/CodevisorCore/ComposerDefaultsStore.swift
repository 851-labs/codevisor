import Foundation

@MainActor
public final class ComposerDefaultsStore {
  public enum Scope: Sendable, Equatable {
    case newWorkspace(serverId: String)

    public var serverId: String {
      switch self {
      case let .newWorkspace(serverId): serverId
      }
    }
  }

  private let store: any PersistenceStore
  private let key: String
  private let migrationBackupKey: String
  private let retiredBackupKeys: [String]
  private let persistenceOwner = UUID()
  private var defaults: ComposerDefaults
  private var persistenceBatchDepth = 0
  private var batchNeedsPersistence = false
  private var batchNeedsImmediatePersistence = false

  public init(store: any PersistenceStore, key: String = "composer-defaults") {
    PersistenceEncoding.drain()
    self.store = store
    self.key = key
    migrationBackupKey = "\(key)-pre-v7-backup"
    retiredBackupKeys = [
      "\(key)-pre-v6-backup",
      "\(key)-pre-v5-backup",
      "\(key)-pre-v4-backup",
      "\(key)-pre-v3-backup",
    ]
    guard let data = store.loadData(forKey: key) else {
      defaults = ComposerDefaults()
      return
    }

    let decoder = JSONDecoder()
    if let current = try? decoder.decode(ComposerDefaults.self, from: data),
      current.version == ComposerDefaults.schemaVersion
    {
      defaults = current
      return
    }

    if let legacy = ComposerDefaultsMigration.decodeLegacy(data, using: decoder) {
      defaults = legacy
      backupAndPersistMigratedPayload(data)
      return
    }

    defaults = ComposerDefaults()
    let error = DecodingError.dataCorrupted(
      .init(codingPath: [], debugDescription: "Unrecognized composer defaults payload")
    )
    handleCorruptPayload(store: store, key: key, data: data, error: error)
  }

  public func lastHarnessId(for scope: Scope) -> String? {
    defaults.machines[scope.serverId]?.lastHarnessId
  }

  public func configSelections(forHarness harnessId: String, model: String?) -> [String: String] {
    defaults.harnesses[harnessId]?.values(forModel: model) ?? [:]
  }

  public func rememberHarnessSelection(serverId: String, harnessId: String?) {
    rememberHarnessSelection(in: .newWorkspace(serverId: serverId), harnessId: harnessId)
  }

  public func rememberHarnessSelection(in scope: Scope, harnessId: String?) {
    guard let harnessId, !harnessId.isEmpty else { return }
    var machine = defaults.machines[scope.serverId] ?? ComposerDefaults.Machine()
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
    var machine = defaults.machines[serverId] ?? ComposerDefaults.Machine()
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
    var machine = defaults.machines[serverId] ?? ComposerDefaults.Machine()
    var byProject = machine.worktreeByProject ?? [:]
    byProject[projectId.uuidString] = createsWorktree
    machine.worktreeByProject = byProject
    defaults.machines[serverId] = machine
    persist()
  }

  public func rememberConfigSelections(
    harnessId: String?,
    modelOptionId: String?,
    configValues: [String: String]
  ) {
    guard let harnessId, !harnessId.isEmpty else { return }
    let configValues = configValues.filter { !$0.value.isEmpty }
    guard !configValues.isEmpty else { return }
    defaults.harnesses[harnessId, default: ComposerHarnessDefaults()]
      .remember(configValues, modelOptionId: modelOptionId)
    persist()
  }

  public func backfillNewWorkspaceDefaults(
    serverId: String,
    projectId: UUID,
    createsWorktree: Bool
  ) {
    var machine = defaults.machines[serverId] ?? ComposerDefaults.Machine()
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
    defaults = ComposerDefaults()
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
}
