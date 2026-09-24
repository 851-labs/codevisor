import Foundation

/// Builds the navigation projection incrementally.
///
/// A rebuild used to recompute every machine and re-fit every workspace's
/// layout on the main actor whenever anything changed -- a mark-read, a pane
/// publish, any other device's edit -- which made navigation slow in exactly
/// the moments it had to feel instant. This keeps the last result per machine
/// and per workspace and recomputes only what the change touched: a machine
/// whose cache, outbox requests, or layouts didn't change is reused whole, and
/// inside a machine only workspaces whose record, panes, layout, or worktree
/// changed are fitted again. Everything it returns is identical to a full
/// rebuild; only the work is smaller.
@MainActor
final class NavigationProjector {
  struct Result {
    var projection: NavigationProjection
    /// Workspaces whose value differs from the previous rebuild, including
    /// ones that are new; views of every other workspace stay untouched.
    var changedWorkspaceIds: Set<UUID>
    /// Workspaces the previous rebuild showed and this one doesn't.
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
    /// Sorted by creation, then id -- the order the whole projection keeps.
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

  /// Forgets everything, so the next rebuild recomputes from scratch.
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
      // Fitting may have saved layouts back; key the memo by what's stored
      // now so the next rebuild doesn't mistake its own save for a change.
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
    // Chats in a worktree workspace all run in the same worktree, so the first
    // one that names it names it for the workspace. One pass, not one per
    // workspace.
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
    // A chat the server hasn't placed in a workspace belongs to the one whose
    // layout shows it -- typically the draft its first message creates.
    for workspace in machine.workspaces {
      for sessionId in workspace.chatSessionIds where machine.sessionIndex[sessionId] == nil {
        machine.sessionIndex[sessionId] = workspace.id
      }
    }
    return machine
  }

  /// A server workspace fitted with this device's layout. The fitted layout
  /// is saved back so tab identities stay stable between rebuilds.
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
    WorkspaceSyncModel.reconcilePanes(in: &workspace, records: key.panes, protectedLocalPaneIds: [])
    let layout = DeviceLayout(workspace)
    if layout != stored { layouts.setLayout(layout, for: workspace.id) }
    return workspace
  }
}

extension UUID {
  /// Tuple of the raw bytes, so ids compare without building strings.
  fileprivate var orderKey: (UInt64, UInt64) {
    withUnsafeBytes(of: uuid) { bytes in
      (bytes.load(as: UInt64.self).bigEndian, bytes.load(fromByteOffset: 8, as: UInt64.self).bigEndian)
    }
  }
}
