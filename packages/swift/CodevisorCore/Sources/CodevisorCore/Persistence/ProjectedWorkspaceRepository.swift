import Foundation

/// The workspace repository the app reads and writes layouts through, backed
/// by the navigation projection instead of a stored copy of server state.
///
/// Reads return the projected workspaces. `save` records only what this
/// device owns -- tabs, splits, selection -- because everything else on a
/// workspace comes from the server and changes only through the outbox.
/// Saving a workspace the server doesn't have yet makes it a draft.
public final class ProjectedWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var workspacesById: [UUID: Workspace] = [:]
  private var ordered: [Workspace] = []
  private var sessionIndex: [UUID: UUID] = [:]
  private let layouts: DeviceLayoutStore
  private let store: NavigationStore?

  @MainActor
  public init(store: NavigationStore) {
    self.store = store
    self.layouts = store.layouts
  }

  @MainActor
  func install(_ projection: NavigationProjection, changed: Set<UUID>, removed: Set<UUID>) {
    lock.withLock {
      workspacesById = projection.workspacesById
      ordered = projection.workspaces
      sessionIndex = projection.sessionIndex
    }
    // The clock keeps a running minimum, so only positions that changed can
    // move it.
    WorkspaceOrderClock.shared.observe(
      changed.compactMap { projection.workspacesById[$0]?.effectiveSidebarPosition }.min())
    store?.workspaceEntries.apply(projection, changed: changed, removed: removed)
  }

  public func loadAll() -> [Workspace] {
    lock.withLock { ordered }
  }

  public func workspace(id: UUID) -> Workspace? {
    lock.withLock { workspacesById[id] }
  }

  public func workspaceId(forSession sessionId: UUID) -> UUID? {
    lock.withLock { sessionIndex[sessionId] }
  }

  public func save(_ workspace: Workspace) {
    guard let current = self.workspace(id: workspace.id) else {
      createDraft(from: workspace)
      return
    }
    var updated = current
    updated.centerTabs = workspace.centerTabs
    updated.selectedCenterTabId = workspace.selectedCenterTabId
    lock.withLock {
      workspacesById[updated.id] = updated
      if let index = ordered.firstIndex(where: { $0.id == updated.id }) { ordered[index] = updated }
      for sessionId in updated.chatSessionIds where sessionIndex[sessionId] == nil {
        sessionIndex[sessionId] = updated.id
      }
    }
    layouts.setLayout(DeviceLayout(updated), for: updated.id)
    // The views showing this workspace update in the same transaction as the
    // click that changed its layout.
    onMain { [weak self] store in
      store.workspaceEntries.update(updated) { self?.workspaceId(forSession: $0) }
    }
  }

  /// Automatic names follow the workspace's context (a new worktree), so the
  /// change goes to the server like any rename, without pinning the name.
  public func setAutomaticName(_ name: String, forWorkspace workspaceId: UUID) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let workspace = workspace(id: workspaceId), !workspace.hasCustomName,
      workspace.name != trimmed
    else { return }
    onMain { store in
      if workspace.isServerSynced {
        store.enqueue(
          .renameWorkspace(workspaceId: workspaceId, name: trimmed, hasCustomName: false),
          machineId: workspace.serverId)
      } else if var draft = store.layouts.draft(id: workspaceId), let layout = store.layouts.layout(for: workspaceId) {
        draft.name = trimmed
        store.addDraft(draft, layout: layout)
      }
    }
  }

  /// Discards a draft, or forgets this device's layout for a workspace.
  /// Removing a workspace from the server is archiving it, which goes
  /// through the outbox.
  public func delete(id: UUID) {
    lock.withLock {
      workspacesById.removeValue(forKey: id)
      ordered.removeAll { $0.id == id }
      sessionIndex = sessionIndex.filter { $0.value != id }
    }
    onMain { store in
      store.workspaceEntries.remove(id)
      store.discardDraft(id: id)
    }
  }

  public func removeAll() {
    lock.withLock {
      workspacesById = [:]
      ordered = []
      sessionIndex = [:]
    }
    layouts.removeAll()
    onMain { $0.rebuild() }
  }

  /// The workspace a chat belongs to. A chat the server has placed opens in
  /// that workspace; a brand-new chat gets a draft workspace whose chat pane
  /// uses the chat's id, which is the id the server gives that pane when
  /// opening the chat creates the workspace -- so the mounted view keeps its
  /// identity when the server's copy arrives.
  public func ensureWorkspace(
    for seed: WorkspaceSessionSeed,
    legacyGroups: (any PaneGroupRepository)?
  ) -> Workspace {
    if let id = workspaceId(forSession: seed.sessionId), let existing = workspace(id: id) {
      return existing
    }
    if let id = seed.assignedWorkspaceId, let assigned = workspace(id: id), assigned.serverId == seed.serverId {
      return assigned
    }
    var center =
      legacyGroups?.load(sessionId: seed.sessionId)
      ?? .centerInitial(sessionId: seed.sessionId, paneId: seed.sessionId)
    for index in center.panes.indices where center.panes[index].kind == .chat {
      if center.panes[index].chatSessionId == nil { center.panes[index].chatSessionId = seed.sessionId }
    }
    // An id another machine's workspace already uses can't be this draft's:
    // the draft would take over that workspace's layout.
    let workspace = Workspace(
      id: seed.assignedWorkspaceId.flatMap { self.workspace(id: $0) == nil ? $0 : nil } ?? UUID(),
      name: seed.initialName.isEmpty ? "Workspace" : seed.initialName,
      rootDirectory: seed.rootDirectory, worktreeName: seed.worktreeName, serverId: seed.serverId,
      projectId: seed.projectId, centerTree: .leaf(center))
    createDraft(from: workspace)
    return self.workspace(id: workspace.id) ?? workspace
  }

  private func createDraft(from workspace: Workspace) {
    let draft = WorkspaceDraft(
      id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId, name: workspace.name,
      rootDirectory: workspace.rootDirectory, worktreeName: workspace.worktreeName,
      createdAt: workspace.createdAt, sidebarPosition: workspace.sidebarPosition)
    let layout = DeviceLayout(workspace)
    lock.withLock {
      workspacesById[workspace.id] = workspace
      if !ordered.contains(where: { $0.id == workspace.id }) { ordered.append(workspace) }
      for sessionId in workspace.chatSessionIds { sessionIndex[sessionId] = workspace.id }
    }
    layouts.addDraft(draft, layout: layout)
    onMain { $0.rebuild() }
  }

  /// Store changes happen on the main actor, where every caller runs.
  private func onMain(_ body: @escaping @MainActor (NavigationStore) -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        guard let store else { return }
        body(store)
      }
    } else {
      Task { @MainActor [weak self] in
        guard let store = self?.store else { return }
        body(store)
      }
    }
  }
}
