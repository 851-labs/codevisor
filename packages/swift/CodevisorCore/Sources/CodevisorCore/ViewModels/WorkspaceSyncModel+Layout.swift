import Foundation

extension WorkspaceSyncModel {
  /// Projects the server's pane registry onto this device's layout.
  ///
  /// The New Tab page is device-local: it is never published, and the
  /// registry never lists it. So local `.newTab` panes are neither created
  /// from nor removed by server records — with one exception. A workspace
  /// showing ONLY the New Tab page (a workspace another client is still
  /// filling, or one whose last pane closed) holds it as a placeholder: the
  /// first real pane fills that tab in place, and any other placeholder tab
  /// is dropped. New Tabs opened beside real panes (⌘T) are kept.
  static func reconcilePanes(
    in workspace: inout Workspace,
    records: [ServerWorkspacePane],
    protectedLocalPaneIds: Set<UUID>
  ) {
    let hadRealPanes = workspace.hasRealPanes
    let selectedTab = workspace.selectedCenterTabId
    let remote = records.compactMap { record -> (ServerWorkspacePane, PaneDescriptorState)? in
      descriptor(from: record).map { (record, $0) }
    }
    let remoteIds = Set(remote.map(\.1.id))
    let remoteIdByResourceKey = Dictionary(
      remote.compactMap { record, descriptor in
        resourceKey(record).map { ($0, descriptor.id) }
      },
      uniquingKeysWith: { first, _ in first }
    )

    for (record, descriptor) in remote {
      if replacePane(id: descriptor.id, with: descriptor, in: &workspace) { continue }
      if let key = resourceKey(record),
        replacePane(resourceKey: key, with: descriptor, in: &workspace)
      {
        continue
      }
      if !hadRealPanes, fillPlaceholderTab(with: descriptor, in: &workspace) { continue }
      let state = PaneGroupState(
        panes: [descriptor], selectedPaneId: descriptor.id
      )
      workspace.centerTabs.append(WorkspaceTab(root: .leaf(state)))
    }

    for pane in allPanes(in: workspace) {
      guard pane.kind != .newTab, !protectedLocalPaneIds.contains(pane.id),
        !remoteIds.contains(pane.id)
      else { continue }
      // Resource matching is an identity-migration fallback, not a
      // reason to retain two panes for one chat. Once the authoritative
      // pane id is present, remove any compatibility pane that refers to
      // the same session.
      if let key = resourceKey(pane), remoteIdByResourceKey[key] != nil {
        _ = removePane(id: pane.id, from: &workspace)
        continue
      }
      _ = removePane(id: pane.id, from: &workspace)
    }
    if !hadRealPanes, workspace.hasRealPanes {
      workspace.centerTabs.removeAll(where: \.isPlaceholder)
    }
    pruneEmptyCenterTabs(in: &workspace)
    if workspace.centerTabs.contains(where: { $0.id == selectedTab }) { workspace.selectedCenterTabId = selectedTab }
    ensureUsableLayout(&workspace)
  }

  /// Gives a pane that has no slot yet the placeholder tab's page, keeping
  /// the tab and leaf identity a mounted view may already hold.
  private static func fillPlaceholderTab(
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    guard let tabIndex = workspace.centerTabs.firstIndex(where: \.isPlaceholder) else { return false }
    let tab = workspace.centerTabs[tabIndex]
    guard
      let leafId = tab.root.group(id: tab.activeLeafId) != nil
        ? tab.activeLeafId : tab.root.allGroups.first?.id
    else { return false }
    workspace.centerTabs[tabIndex].root = tab.root.updatingGroup(id: leafId) { state in
      var state = state
      state.panes = [pane]
      state.selectedPaneId = pane.id
      return state
    }
    workspace.centerTabs[tabIndex].activeLeafId = leafId
    return true
  }

  static func allPanes(in workspace: Workspace) -> [PaneDescriptorState] {
    workspace.centerTabs.flatMap { tab in
      tab.root.allGroups.flatMap(\.state.panes)
    }
  }

  static func resourceKey(_ pane: PaneDescriptorState) -> String? {
    switch pane.kind {
    case .chat:
      pane.chatSessionId.map { "session:\($0.uuidString.lowercased())" }
    case .terminal:
      "terminal:\(pane.terminalKey.lowercased())"
    case .newTab, .plugin, .document, .browser, .screenSharing:
      nil
    }
  }

  static func resourceKey(_ pane: ServerWorkspacePane) -> String? {
    guard let kind = pane.resourceKind, let id = pane.resourceId else { return nil }
    // Files are case-sensitive resources, and document tabs deduplicate by
    // their canonical path in the UI rather than this legacy migration key.
    guard kind != "file" else { return nil }
    return "\(kind.lowercased()):\(id.lowercased())"
  }

  static func replacePane(
    id: UUID,
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    replacePane(where: { $0.id == id }, with: pane, in: &workspace)
  }

  private static func replacePane(
    resourceKey key: String,
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    replacePane(where: { resourceKey($0) == key }, with: pane, in: &workspace)
  }

  private static func replacePane(
    where matches: (PaneDescriptorState) -> Bool,
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    for tabIndex in workspace.centerTabs.indices {
      for group in workspace.centerTabs[tabIndex].root.allGroups {
        guard let paneIndex = group.state.panes.firstIndex(where: matches) else { continue }
        workspace.centerTabs[tabIndex].root = workspace.centerTabs[tabIndex].root.updatingGroup(
          id: group.id
        ) { state in
          var state = state
          let oldId = state.panes[paneIndex].id
          state.panes[paneIndex] = pane
          if state.selectedPaneId == oldId { state.selectedPaneId = pane.id }
          return state
        }
        return true
      }
    }
    return false
  }

  @discardableResult
  static func removePane(id: UUID, from workspace: inout Workspace) -> Bool {
    var removed = false
    for tabIndex in workspace.centerTabs.indices.reversed() {
      var root = workspace.centerTabs[tabIndex].root
      for group in root.allGroups where group.state.panes.contains(where: { $0.id == id }) {
        root = root.updatingGroup(id: group.id) { state in
          var state = state
          removed = state.removePane(id: id) != nil || removed
          return state
        }
      }
      if let pruned = root.prunedEmptyGroups {
        workspace.centerTabs[tabIndex].root = pruned
      } else {
        workspace.centerTabs.remove(at: tabIndex)
      }
    }
    return removed
  }

  static func ensureUsableLayout(_ workspace: inout Workspace) {
    guard workspace.centerTabs.isEmpty else {
      if !workspace.centerTabs.contains(where: { $0.id == workspace.selectedCenterTabId }),
        let firstId = workspace.centerTabs.first?.id
      {
        workspace.selectedCenterTabId = firstId
      }
      return
    }
    let tab = WorkspaceTab.placeholder()
    workspace.centerTabs = [tab]
    workspace.selectedCenterTabId = tab.id
  }

  static func pruneEmptyCenterTabs(in workspace: inout Workspace) {
    workspace.centerTabs = workspace.centerTabs.compactMap { tab in
      guard let root = tab.root.prunedEmptyGroups else { return nil }
      var tab = tab
      tab.root = root
      if root.group(id: tab.activeLeafId) == nil, let first = root.allGroups.first?.id {
        tab.activeLeafId = first
      }
      return tab
    }
  }

  static func makeWorkspace(
    id: UUID,
    projectId: UUID,
    serverId: String,
    record: ServerWorkspace,
    createdAt: Date,
    worktreeName: String?,
    sessionIds: [UUID],
    usesPaneRegistry: Bool
  ) -> Workspace {
    let tabs: [WorkspaceTab]
    if usesPaneRegistry || sessionIds.isEmpty {
      tabs = [WorkspaceTab.placeholder()]
    } else {
      tabs = sessionIds.map {
        WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0)))
      }
    }
    return Workspace(
      id: id,
      name: record.name,
      hasCustomName: record.hasCustomName,
      rootDirectory: record.rootDirectory,
      worktreeName: worktreeName,
      serverId: serverId,
      projectId: projectId,
      centerTabs: tabs,
      createdAt: createdAt,
      isArchived: record.isArchived,
      isServerSynced: true
    )
  }

  static func date(from value: String) -> Date? {
    try? ServerDateCoding.date(from: value)
  }
}
