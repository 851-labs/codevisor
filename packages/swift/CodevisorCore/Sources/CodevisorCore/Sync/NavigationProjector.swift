import Foundation

@MainActor
final class NavigationProjector {
  struct Result {
    var projection: NavigationProjection
    var changedWorkspaceIds: Set<UUID>
    var removedWorkspaceIds: Set<UUID>
  }

  private struct MachineInputs: Equatable {
    var cacheGeneration: UInt64?
    var entries: [NavigationOutboxEntry]
    var layoutGeneration: UInt64
    var yielded: Set<UUID>
  }

  private struct MachineProjection {
    var projects: [Project] = []
    var sessions: [ChatSession] = []
    var workspaces: [Workspace] = []
    var sessionIndex: [UUID: UUID] = [:]
    var checkouts: [String: Checkout] = [:]
  }

  private struct WorkspaceKey: Equatable {
    var record: ServerWorkspace
    var panes: [ServerWorkspacePane]
    var layoutGeneration: UInt64
    var worktreeName: String?
  }

  private var machines: [String: (inputs: MachineInputs, projection: MachineProjection)] = [:]
  private var fitted: [UUID: (key: WorkspaceKey, workspace: Workspace)] = [:]
  private var previous: [UUID: Workspace] = [:]
  private let ownership = WorkspaceOwnership()

  func reset() {
    machines = [:]
    fitted = [:]
  }

  func project(
    machineIds: [String],
    cache: (String) -> MachineNavigationCache?,
    cacheGeneration: (String) -> UInt64?,
    entries: (String) -> [NavigationOutboxEntry],
    restoring: [UUID: RestoringWorkspace] = [:],
    layouts: DeviceLayoutStore
  ) -> Result {
    var projection = NavigationProjection()
    var current: [String: (inputs: MachineInputs, projection: MachineProjection)] = [:]
    let yielded = ownership.yieldedWorkspaces(machineIds: machineIds, cache: cache, cacheGeneration: cacheGeneration)
    for machineId in machineIds {
      let inputs = MachineInputs(
        cacheGeneration: cacheGeneration(machineId), entries: entries(machineId),
        layoutGeneration: layouts.machineGeneration(machineId), yielded: yielded[machineId] ?? [])
      let machine: MachineProjection
      if let memo = machines[machineId], memo.inputs == inputs {
        machine = memo.projection
      } else {
        machine = projectMachine(machineId, cache: cache(machineId), inputs: inputs, layouts: layouts)
      }
      current[machineId] = (
        MachineInputs(
          cacheGeneration: inputs.cacheGeneration, entries: inputs.entries,
          layoutGeneration: layouts.machineGeneration(machineId), yielded: inputs.yielded),
        machine
      )
      projection.projects += machine.projects
      projection.sessions += machine.sessions
      projection.workspaces += machine.workspaces
      projection.sessionIndex.merge(machine.sessionIndex) { _, new in new }
      projection.checkouts.merge(machine.checkouts) { _, new in new }
    }
    machines = current
    restoring.mark(&projection.workspaces, held: previous)
    var changed = Set<UUID>()
    var byId: [UUID: Workspace] = [:]
    byId.reserveCapacity(projection.workspaces.count)
    for workspace in projection.workspaces {
      byId[workspace.id] = workspace
      if previous[workspace.id] != workspace { changed.insert(workspace.id) }
    }
    projection.workspacesById = byId
    let removed = Set(previous.keys).subtracting(byId.keys)
    previous = byId
    fitted = fitted.filter { byId[$0.key] != nil }
    return Result(projection: projection, changedWorkspaceIds: changed, removedWorkspaceIds: removed)
  }

  private func projectMachine(
    _ machineId: String, cache: MachineNavigationCache?, inputs: MachineInputs, layouts: DeviceLayoutStore
  ) -> MachineProjection {
    var records = NavigationRecords(cache)
    NavigationOverlay.apply(inputs.entries, to: &records)
    records.yield(inputs.yielded)
    var machine = MachineProjection(projects: records.projects, sessions: records.sessions)
    machine.checkouts = Dictionary(
      records.checkouts.map { ($0.id.lowercased(), Checkout(record: $0, machineId: machineId)) },
      uniquingKeysWith: { _, new in new })
    let panesByWorkspace = Dictionary(grouping: records.panes) { $0.workspaceId.lowercased() }
    let worktreeNames = Self.worktreeNames(in: records)
    var serverWorkspaceIds = Set<UUID>()
    for record in records.workspaces {
      guard let id = UUID(uuidString: record.id) else { continue }
      let key = WorkspaceKey(
        record: record, panes: panesByWorkspace[record.id.lowercased()] ?? [],
        layoutGeneration: layouts.workspaceGeneration(id), worktreeName: worktreeNames[id])
      if let memo = fitted[id], memo.key == key {
        machine.workspaces.append(memo.workspace)
        serverWorkspaceIds.insert(id)
        continue
      }
      guard let workspace = fit(record, key: key, machineId: machineId, layouts: layouts) else { continue }
      var storedKey = key
      storedKey.layoutGeneration = layouts.workspaceGeneration(id)
      fitted[id] = (storedKey, workspace)
      machine.workspaces.append(workspace)
      serverWorkspaceIds.insert(id)
    }
    for draft in layouts.drafts where draft.serverId == machineId && !serverWorkspaceIds.contains(draft.id) {
      guard !inputs.yielded.contains(draft.id) else { continue }
      guard let layout = layouts.layout(for: draft.id), !layout.tabs.isEmpty else { continue }
      machine.workspaces.append(NavigationProjectionBuilder.workspace(from: draft, layout: layout))
    }
    machine.workspaces.sort { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.orderKey < rhs.id.orderKey
    }
    machine.sessionIndex = records.assignments
    for workspace in machine.workspaces {
      for sessionId in workspace.chatSessionIds where machine.sessionIndex[sessionId] == nil {
        machine.sessionIndex[sessionId] = workspace.id
      }
    }
    return machine
  }

  private static func worktreeNames(in records: NavigationRecords) -> [UUID: String] {
    let mainSessionIds = Set(records.workspaces.compactMap { $0.mainSessionId.flatMap(UUID.init(uuidString:)) })
    var names: [UUID: String] = [:]
    var fromMain = Set<UUID>()
    for session in records.sessions {
      guard let workspaceId = records.assignments[session.id] else { continue }
      if mainSessionIds.contains(session.id) {
        names[workspaceId] = session.worktreeName
        fromMain.insert(workspaceId)
      } else if !fromMain.contains(workspaceId), names[workspaceId] == nil, let name = session.worktreeName {
        names[workspaceId] = name
      }
    }
    return names
  }

  private func fit(
    _ record: ServerWorkspace, key: WorkspaceKey, machineId: String, layouts: DeviceLayoutStore
  ) -> Workspace? {
    guard
      var workspace = NavigationProjectionBuilder.workspace(
        from: record, machineId: machineId, worktreeName: key.worktreeName)
    else { return nil }
    let stored = layouts.layout(for: workspace.id)
    if let stored {
      workspace.centerTabs = stored.tabs.isEmpty ? [WorkspaceTab.placeholder()] : stored.tabs
      workspace.selectedCenterTabId = stored.selectedTabId
    }
    WorkspacePaneReconciler(records: key.panes, protectedLocalPaneIds: localPaneIds(of: workspace, layouts: layouts))
      .reconcile(&workspace)
    if layouts.isBotWorkspace(workspace.id) { workspace.foldTabsIntoSplits() }
    let layout = DeviceLayout(workspace)
    if layout != stored { layouts.setLayout(layout, for: workspace.id) }
    return workspace
  }

  private func localPaneIds(of workspace: Workspace, layouts: DeviceLayoutStore) -> Set<UUID> {
    Set(workspace.allPanes.filter { layouts.keepsOnDevice($0, in: workspace.id) }.map(\.id))
  }
}

extension UUID {
  fileprivate var orderKey: (UInt64, UInt64) {
    withUnsafeBytes(of: uuid) { bytes in
      (bytes.load(as: UInt64.self).bigEndian, bytes.load(fromByteOffset: 8, as: UInt64.self).bigEndian)
    }
  }
}

extension [UUID: RestoringWorkspace] {
  fileprivate func mark(_ workspaces: inout [Workspace], held: [UUID: Workspace]) {
    guard !isEmpty else { return }
    var listed = Set<UUID>()
    for index in workspaces.indices {
      guard let restoring = self[workspaces[index].id] else { continue }
      listed.insert(workspaces[index].id)
      let isOnSandbox = workspaces[index].serverId == restoring.sandboxMachineId
      workspaces[index].isRestoring = !isOnSandbox && !workspaces[index].isArchived
    }
    for id in keys where !listed.contains(id) {
      guard let workspace = held[id], workspace.isRestoring else { continue }
      workspaces.append(workspace)
    }
  }
}
