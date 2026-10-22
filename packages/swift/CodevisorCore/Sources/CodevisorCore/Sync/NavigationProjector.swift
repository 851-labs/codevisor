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
  }

  private struct MachineProjection {
    var projects: [Project] = []
    var sessions: [ChatSession] = []
    var workspaces: [Workspace] = []
    var sessionIndex: [UUID: UUID] = [:]
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

  func reset() {
    machines = [:]
    fitted = [:]
  }

  func project(
    machineIds: [String],
    cache: (String) -> MachineNavigationCache?,
    cacheGeneration: (String) -> UInt64?,
    entries: (String) -> [NavigationOutboxEntry],
    layouts: DeviceLayoutStore
  ) -> Result {
    var projection = NavigationProjection()
    var current: [String: (inputs: MachineInputs, projection: MachineProjection)] = [:]
    for machineId in machineIds {
      let inputs = MachineInputs(
        cacheGeneration: cacheGeneration(machineId), entries: entries(machineId),
        layoutGeneration: layouts.machineGeneration(machineId))
      let machine: MachineProjection
      if let memo = machines[machineId], memo.inputs == inputs {
        machine = memo.projection
      } else {
        machine = projectMachine(machineId, cache: cache(machineId), entries: inputs.entries, layouts: layouts)
      }
      current[machineId] = (
        MachineInputs(
          cacheGeneration: inputs.cacheGeneration, entries: inputs.entries,
          layoutGeneration: layouts.machineGeneration(machineId)),
        machine
      )
      projection.projects += machine.projects
      projection.sessions += machine.sessions
      projection.workspaces += machine.workspaces
      projection.sessionIndex.merge(machine.sessionIndex) { _, new in new }
    }
    machines = current
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
    _ machineId: String, cache: MachineNavigationCache?, entries: [NavigationOutboxEntry],
    layouts: DeviceLayoutStore
  ) -> MachineProjection {
    var records = NavigationRecords(cache)
    NavigationOverlay.apply(entries, to: &records)
    var machine = MachineProjection(projects: records.projects, sessions: records.sessions)
    let panesByWorkspace = Dictionary(grouping: records.panes) { $0.workspaceId.lowercased() }
    var worktreeNames: [UUID: String] = [:]
    for session in records.sessions {
      guard let name = session.worktreeName, let workspaceId = records.assignments[session.id],
        worktreeNames[workspaceId] == nil
      else { continue }
      worktreeNames[workspaceId] = name
    }
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
    WorkspacePaneReconciler(records: key.panes, protectedLocalPaneIds: []).reconcile(&workspace)
    let layout = DeviceLayout(workspace)
    if layout != stored { layouts.setLayout(layout, for: workspace.id) }
    return workspace
  }
}

extension UUID {
  fileprivate var orderKey: (UInt64, UInt64) {
    withUnsafeBytes(of: uuid) { bytes in
      (bytes.load(as: UInt64.self).bigEndian, bytes.load(fromByteOffset: 8, as: UInt64.self).bigEndian)
    }
  }
}
