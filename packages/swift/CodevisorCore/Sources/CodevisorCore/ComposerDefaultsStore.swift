import Foundation

/// Persists explicit composer and workspace-creation selections.
///
/// A machine-scoped profile drives the standalone New Chat page: project,
/// worktree choice, harness, and per-harness model/reasoning/speed values.
/// Every workspace has a separate profile representing the last chat focused
/// there. New chat tabs and splits inherit that profile without leaking their
/// choices into the standalone page or another workspace.
@MainActor
public final class ComposerDefaultsStore {
  nonisolated private static let schemaVersion = 5
  nonisolated private static let legacyServerId = "local"

  public enum Scope: Sendable, Equatable {
    case newWorkspace(serverId: String)
    case workspace(id: UUID, serverId: String)

    public var serverId: String {
      switch self {
      case let .newWorkspace(serverId), let .workspace(_, serverId):
        serverId
      }
    }
  }

  fileprivate struct MachineDefaults: Codable, Sendable {
    var lastHarnessId: String?
    /// The project used by the last standalone New Chat page on this
    /// machine. UUIDs that no longer exist are ignored by callers.
    var lastProjectId: UUID?
    /// Whether the last workspace created on this machine used a fresh
    /// git worktree — seeds the New Workspace form's toggle.
    var newWorkspaceInWorktree: Bool?
    /// Config option selections keyed by harness id, then option id.
    /// Keeping every harness here is important: changing harnesses should
    /// restore that harness's own model/reasoning/speed selections.
    var configSelections: [String: [String: String]] = [:]
  }

  fileprivate struct WorkspaceDefaults: Codable, Sendable {
    /// Protects against a stale workspace id being interpreted under a
    /// different machine after an import.
    var serverId: String?
    var lastHarnessId: String?
    var configSelections: [String: [String: String]] = [:]
  }

  private struct Defaults: Codable, Sendable {
    var version = ComposerDefaultsStore.schemaVersion
    /// The machine targeted by the standalone New Chat composer most
    /// recently. Navigation never writes this; explicit composer project
    /// choices and successful first sends do.
    var lastNewWorkspaceServerId: String?
    var machines: [String: MachineDefaults] = [:]
    var workspaces: [String: WorkspaceDefaults] = [:]
  }

  private let store: any PersistenceStore
  private let key: String
  private let migrationBackupKey: String
  private let previousMigrationBackupKey: String
  private let legacyMigrationBackupKey: String
  private let persistenceOwner = UUID()
  private var defaults: Defaults
  private var persistenceBatchDepth = 0
  private var batchNeedsPersistence = false
  private var batchNeedsImmediatePersistence = false

  public init(store: any PersistenceStore, key: String = "composer-defaults") {
    // A previous live instance may still have a coalesced snapshot on the
    // shared encode queue (tests and in-process environment replacement do
    // this routinely). Preserve the repository read-your-writes contract.
    PersistenceEncoding.drain()
    self.store = store
    self.key = key
    migrationBackupKey = "\(key)-pre-v5-backup"
    previousMigrationBackupKey = "\(key)-pre-v4-backup"
    legacyMigrationBackupKey = "\(key)-pre-v3-backup"
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

    if let version4 = try? decoder.decode(DefaultsV4.self, from: data),
      version4.version == 4
    {
      defaults = Defaults(
        machines: version4.machines,
        workspaces: version4.workspaces
      )
      backupAndPersistMigratedPayload(data)
      return
    }

    if let version3 = try? decoder.decode(DefaultsV3.self, from: data),
      version3.version == 3
    {
      let recoveredWorkspaces =
        store.loadData(forKey: legacyMigrationBackupKey)
        .flatMap { try? decoder.decode(ScopedDefaultsV2.self, from: $0) }
        .map(Self.workspaceDefaults(from:)) ?? [:]
      defaults = Defaults(
        machines: version3.machines.mapValues { machine in
          MachineDefaults(
            lastHarnessId: machine.lastHarnessId,
            newWorkspaceInWorktree: machine.newWorkspaceInWorktree,
            configSelections: machine.configSelections ?? [:]
          )
        },
        workspaces: recoveredWorkspaces
      )
      backupAndPersistMigratedPayload(data)
      return
    }

    if let scoped = try? decoder.decode(ScopedDefaultsV2.self, from: data) {
      defaults = Defaults(
        machines: scoped.machines.mapValues { machine in
          MachineDefaults(
            lastHarnessId: machine.lastHarnessId,
            configSelections: machine.configSelections ?? [:]
          )
        },
        workspaces: Self.workspaceDefaults(from: scoped)
      )
      backupAndPersistMigratedPayload(data)
      return
    }

    if let flat = try? decoder.decode(FlatDefaultsV1.self, from: data), flat.isRecognized {
      defaults = Defaults(machines: [
        Self.legacyServerId: MachineDefaults(
          lastHarnessId: flat.lastHarnessId,
          configSelections: flat.configSelections ?? [:]
        )
      ])
      backupAndPersistMigratedPayload(data)
      return
    }

    defaults = Defaults()
    let error = DecodingError.dataCorrupted(
      .init(codingPath: [], debugDescription: "Unrecognized composer defaults payload")
    )
    handleCorruptPayload(store: store, key: key, data: data, error: error)
  }

  private static func workspaceDefaults(
    from scoped: ScopedDefaultsV2
  ) -> [String: WorkspaceDefaults] {
    (scoped.workspaces ?? [:]).mapValues { workspace in
      WorkspaceDefaults(
        lastHarnessId: workspace.lastHarnessId,
        configSelections: workspace.configSelections ?? [:]
      )
    }
  }

  /// The harness most recently selected in a composer on this machine.
  public func lastHarnessId(forServer serverId: String) -> String? {
    lastHarnessId(for: .newWorkspace(serverId: serverId))
  }

  /// The harness a new composer in this scope should start with.
  public func lastHarnessId(for scope: Scope) -> String? {
    switch scope {
    case let .newWorkspace(serverId):
      return defaults.machines[serverId]?.lastHarnessId
    case let .workspace(id, serverId):
      guard let workspace = workspaceDefaults(id: id, serverId: serverId) else {
        return nil
      }
      return workspace.lastHarnessId
    }
  }

  /// The remembered option ids and values for one harness on this machine.
  public func configSelections(
    forHarness harnessId: String,
    onServer serverId: String
  ) -> [String: String] {
    configSelections(
      forHarness: harnessId,
      in: .newWorkspace(serverId: serverId)
    )
  }

  /// The remembered option ids and values for one harness in this scope.
  public func configSelections(
    forHarness harnessId: String,
    in scope: Scope
  ) -> [String: String] {
    switch scope {
    case let .newWorkspace(serverId):
      return defaults.machines[serverId]?.configSelections[harnessId] ?? [:]
    case let .workspace(id, serverId):
      return workspaceDefaults(id: id, serverId: serverId)?
        .configSelections[harnessId] ?? [:]
    }
  }

  /// Records an explicit harness picker action immediately.
  public func rememberHarnessSelection(serverId: String, harnessId: String?) {
    rememberHarnessSelection(
      in: .newWorkspace(serverId: serverId),
      harnessId: harnessId
    )
  }

  /// Records an explicit harness picker action in the appropriate profile.
  public func rememberHarnessSelection(in scope: Scope, harnessId: String?) {
    guard let harnessId, !harnessId.isEmpty else { return }
    switch scope {
    case let .newWorkspace(serverId):
      var machine = defaults.machines[serverId] ?? MachineDefaults()
      machine.lastHarnessId = harnessId
      defaults.machines[serverId] = machine
    case let .workspace(id, serverId):
      var workspace =
        workspaceDefaults(id: id, serverId: serverId)
        ?? WorkspaceDefaults(serverId: serverId)
      workspace.serverId = serverId
      workspace.lastHarnessId = harnessId
      defaults.workspaces[id.uuidString] = workspace
    }
    persist()
  }

  /// The project used by the last standalone New Chat page on this machine.
  public func lastProjectId(forServer serverId: String) -> UUID? {
    defaults.machines[serverId]?.lastProjectId
  }

  /// The standalone New Chat composer's last explicit machine target.
  /// This is a composer preference, not application navigation state.
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

  /// Whether the last workspace created on this machine used a fresh git
  /// worktree. Seeds the New Workspace form's toggle; false until a
  /// workspace has been created.
  public func prefersWorktreeForNewWorkspaces(forServer serverId: String) -> Bool {
    defaults.machines[serverId]?.newWorkspaceInWorktree ?? false
  }

  /// Records the worktree choice a workspace was created with, so the next
  /// New Workspace form starts from it — same policy as the last-used
  /// harness.
  public func rememberNewWorkspaceWorktreePreference(
    serverId: String,
    createsWorktree: Bool
  ) {
    var machine = defaults.machines[serverId] ?? MachineDefaults()
    machine.newWorkspaceInWorktree = createsWorktree
    defaults.machines[serverId] = machine
    persist()
  }

  /// Merges the latest known model/reasoning/speed values for one harness.
  /// Missing ids are retained because some options (notably speed) disappear
  /// temporarily when the selected model does not support them.
  public func rememberConfigSelections(
    serverId: String,
    harnessId: String?,
    configValues: [String: String]
  ) {
    rememberConfigSelections(
      in: .newWorkspace(serverId: serverId),
      harnessId: harnessId,
      configValues: configValues
    )
  }

  /// Merges explicit picker changes into the relevant profile.
  public func rememberConfigSelections(
    in scope: Scope,
    harnessId: String?,
    configValues: [String: String]
  ) {
    guard let harnessId, !harnessId.isEmpty, !configValues.isEmpty else { return }
    switch scope {
    case let .newWorkspace(serverId):
      var machine = defaults.machines[serverId] ?? MachineDefaults()
      var selections = machine.configSelections[harnessId] ?? [:]
      selections.merge(configValues) { _, latest in latest }
      machine.configSelections[harnessId] = selections
      defaults.machines[serverId] = machine
    case let .workspace(id, serverId):
      var workspace =
        workspaceDefaults(id: id, serverId: serverId)
        ?? WorkspaceDefaults(serverId: serverId)
      var selections = workspace.configSelections[harnessId] ?? [:]
      selections.merge(configValues) { _, latest in latest }
      workspace.serverId = serverId
      workspace.configSelections[harnessId] = selections
      defaults.workspaces[id.uuidString] = workspace
    }
    persist()
  }

  /// Makes one chat the workspace's inheritance source. Unlike picker
  /// changes, focusing a different chat replaces that harness's snapshot:
  /// hidden values from the previously focused chat must not bleed into it.
  public func rememberFocusedChat(
    workspaceId: UUID,
    serverId: String,
    harnessId: String?,
    configValues: [String: String]
  ) {
    guard let harnessId, !harnessId.isEmpty else { return }
    var workspace =
      workspaceDefaults(id: workspaceId, serverId: serverId)
      ?? WorkspaceDefaults(serverId: serverId)
    workspace.serverId = serverId
    workspace.lastHarnessId = harnessId
    if !configValues.isEmpty {
      workspace.configSelections[harnessId] = configValues
    }
    defaults.workspaces[workspaceId.uuidString] = workspace
    persist()
  }

  /// One-time backfill for clients that predate standalone-page project
  /// memory. Existing explicit choices always win.
  public func backfillNewWorkspaceDefaults(
    serverId: String,
    projectId: UUID,
    createsWorktree: Bool,
    harnessId: String?,
    configValues: [String: String]
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
    if machine.lastHarnessId == nil, let harnessId, !harnessId.isEmpty {
      machine.lastHarnessId = harnessId
      changed = true
    }
    if let harnessId, !harnessId.isEmpty,
      machine.configSelections[harnessId] == nil,
      !configValues.isEmpty
    {
      machine.configSelections[harnessId] = configValues
      changed = true
    }
    guard changed else { return }
    defaults.machines[serverId] = machine
    persist()
  }

  /// One-time workspace backfill from the best available persisted chat.
  /// A V2-restored or already-focused profile is never overwritten.
  public func backfillWorkspaceDefaults(
    workspaceId: UUID,
    serverId: String,
    harnessId: String?,
    configValues: [String: String]
  ) {
    guard defaults.workspaces[workspaceId.uuidString] == nil,
      let harnessId, !harnessId.isEmpty
    else { return }
    defaults.workspaces[workspaceId.uuidString] = WorkspaceDefaults(
      serverId: serverId,
      lastHarnessId: harnessId,
      configSelections: configValues.isEmpty ? [:] : [harnessId: configValues]
    )
    persist()
  }

  /// Groups a logical UI transaction into one encoded persistence snapshot.
  /// First-send promotion updates both the machine defaults and the new
  /// workspace profile; writing each intermediate shape wastes several
  /// main-run-loop-adjacent SQLite transactions and has no durability value.
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

  /// Clears remembered selections and the migration safety copy (used by
  /// "Delete all data").
  public func clear() {
    defaults = Defaults()
    for backupKey in [
      migrationBackupKey,
      previousMigrationBackupKey,
      legacyMigrationBackupKey,
    ] {
      do {
        try store.removeData(forKey: backupKey)
      } catch {
        Log.persistence.error(
          "Failed to remove \(backupKey, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
    persist()
  }

  private func workspaceDefaults(id: UUID, serverId: String) -> WorkspaceDefaults? {
    guard let workspace = defaults.workspaces[id.uuidString],
      workspace.serverId == nil || workspace.serverId == serverId
    else {
      return nil
    }
    return workspace
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

  /// Forces the latest in-memory defaults through the background encoder.
  /// Intended for tests and explicit lifecycle barriers, not hot UI paths.
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
}

private extension ComposerDefaultsStore {
  /// V4 introduced project/worktree memory and workspace-scoped profiles,
  /// but still relied on the app-wide selected machine to choose which
  /// machine the standalone composer opened on.
  struct DefaultsV4: Decodable {
    var version: Int?
    fileprivate var machines: [String: MachineDefaults]
    fileprivate var workspaces: [String: WorkspaceDefaults]
  }

  /// The format shipped immediately before workspace-scoped inheritance.
  struct DefaultsV3: Decodable {
    var version: Int?
    var machines: [String: MachineDefaultsV3]
  }

  struct MachineDefaultsV3: Decodable {
    var lastHarnessId: String?
    var newWorkspaceInWorktree: Bool?
    var configSelections: [String: [String: String]]?
  }

  /// V2 already carried workspace snapshots. V3 retired them; V4 restores
  /// the feature with clearer "last focused chat" semantics. Preserve V2
  /// snapshots both on a direct upgrade and from V3's safety backup.
  struct ScopedDefaultsV2: Decodable {
    var machines: [String: MachineDefaultsV2]
    var workspaces: [String: WorkspaceDefaultsV2]?
  }

  struct MachineDefaultsV2: Decodable {
    var lastHarnessId: String?
    /// Legacy field, decode-only: run location is no longer remembered.
    var runInWorktree: Bool?
    var configSelections: [String: [String: String]]?
  }

  struct WorkspaceDefaultsV2: Decodable {
    var lastHarnessId: String?
    var configSelections: [String: [String: String]]?
  }

  /// The flat pre-machine-scoping payload. All fields remain optional so a
  /// partial legacy file still migrates rather than being quarantined.
  struct FlatDefaultsV1: Decodable {
    var lastHarnessId: String?
    var runInWorktree: Bool?
    var configSelections: [String: [String: String]]?

    var isRecognized: Bool {
      lastHarnessId != nil || runInWorktree != nil || configSelections != nil
    }
  }
}
