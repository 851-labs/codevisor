import Foundation

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
    WorkspaceOrderClock.shared.observe(
      changed.compactMap { projection.workspacesById[$0]?.effectiveSidebarPosition }.min())
    WorkspaceOrderClock.shared.observeDrafts(
      Dictionary(
        projection.workspaces.filter(\.isDraft).map { ($0.id, $0.effectiveSidebarPosition) },
        uniquingKeysWith: { first, _ in first }))
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
    let reordered = current.centerTabs.map(\.id) != updated.centerTabs.map(\.id)
    onMain { [weak self] store in
      store.workspaceEntries.update(updated) { self?.workspaceId(forSession: $0) }
      if reordered { store.publishTabOrder(of: updated) }
    }
  }

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
