import Foundation

nonisolated struct WorkspacePaneReconciler {
  private let records: [ServerWorkspacePane]
  private let protectedLocalPaneIds: Set<UUID>
  private let remotePanes: [RemotePane]

  init(records: [ServerWorkspacePane], protectedLocalPaneIds: Set<UUID>) {
    self.records = records
    self.protectedLocalPaneIds = protectedLocalPaneIds
    remotePanes = records.compactMap(RemotePane.init)
  }

  func reconcile(_ workspace: inout Workspace) {
    let previous = workspace
    let hadRealPanes = previous.hasRealPanes

    applyRemotePanes(to: &workspace, canFillPlaceholder: !hadRealPanes)
    removeDroppedPanes(from: &workspace)
    tidyTabs(in: &workspace, hadRealPanes: hadRealPanes)
    restoreSelection(in: &workspace, previous: previous)
  }

  private func applyRemotePanes(to workspace: inout Workspace, canFillPlaceholder: Bool) {
    for remote in remotePanes {
      place(remote, in: &workspace, canFillPlaceholder: canFillPlaceholder)
    }
  }

  private func place(_ remote: RemotePane, in workspace: inout Workspace, canFillPlaceholder: Bool) {
    if Self.replacePane(id: remote.descriptor.id, with: remote.descriptor, in: &workspace) { return }
    if Self.replacePaneSharingResource(with: remote, in: &workspace) { return }
    if canFillPlaceholder, Self.fillPlaceholderTab(with: remote.descriptor, in: &workspace) { return }

    let state = PaneGroupState(panes: [remote.descriptor], selectedPaneId: remote.descriptor.id)
    workspace.centerTabs.append(WorkspaceTab(root: .leaf(state)))
  }

  private func removeDroppedPanes(from workspace: inout Workspace) {
    let remoteIds = Set(remotePanes.map(\.descriptor.id))
    for pane in workspace.allPanes where isDropped(pane, remoteIds: remoteIds) {
      Self.removePane(id: pane.id, from: &workspace)
    }
  }

  private func isDropped(_ pane: PaneDescriptorState, remoteIds: Set<UUID>) -> Bool {
    !pane.kind.isDeviceLocal && !protectedLocalPaneIds.contains(pane.id) && !remoteIds.contains(pane.id)
  }

  private func tidyTabs(in workspace: inout Workspace, hadRealPanes: Bool) {
    workspace.pruneOrphanedSubagentPanes()
    if !hadRealPanes, workspace.hasRealPanes {
      workspace.centerTabs.removeAll(where: \.isPlaceholder)
    }
    Self.pruneEmptyCenterTabs(in: &workspace)
    workspace.centerTabs = SharedTabOrder.sorted(
      workspace.centerTabs, positions: SharedTabOrder.positions(of: records, workspaceId: nil))
  }

  private func restoreSelection(in workspace: inout Workspace, previous: Workspace) {
    let selectedTab = previous.selectedCenterTabId
    if workspace.centerTabs.contains(where: { $0.id == selectedTab }) {
      workspace.selectedCenterTabId = selectedTab
    } else {
      workspace.selectReplacementForClosedTab(selectedTab, previousTabs: previous.centerTabs)
    }
    Self.ensureUsableLayout(&workspace)
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

  private static func fillPlaceholderTab(
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    guard let tabIndex = workspace.centerTabs.firstIndex(where: \.isPlaceholder) else { return false }
    let tab = workspace.centerTabs[tabIndex]
    guard let leafId = fillableLeafId(in: tab) else { return false }

    workspace.centerTabs[tabIndex].root = tab.root.updatingGroup(id: leafId) { state in
      var state = state
      state.panes = [pane]
      state.selectedPaneId = pane.id
      return state
    }
    workspace.centerTabs[tabIndex].activeLeafId = leafId
    return true
  }

  private static func fillableLeafId(in tab: WorkspaceTab) -> UUID? {
    if tab.root.group(id: tab.activeLeafId) != nil { return tab.activeLeafId }
    return tab.root.allGroups.first?.id
  }

  private static func replacePane(
    id: UUID,
    with pane: PaneDescriptorState,
    in workspace: inout Workspace
  ) -> Bool {
    replacePane(where: { $0.id == id }, with: pane, in: &workspace)
  }

  private static func replacePaneSharingResource(
    with remote: RemotePane,
    in workspace: inout Workspace
  ) -> Bool {
    guard let key = remote.resourceKey else { return false }
    return replacePane(where: { resourceKey($0) == key }, with: remote.descriptor, in: &workspace)
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

  private static func resourceKey(_ pane: PaneDescriptorState) -> String? {
    switch pane.kind {
    case .chat:
      pane.chatSessionId.map { "session:\($0.uuidString.lowercased())" }
    case .terminal:
      "terminal:\(pane.terminalKey.lowercased())"
    case .newTab, .plugin, .document, .browser, .screenSharing, .subagent, .review, .simulator, .transcript:
      nil
    }
  }
}

private nonisolated struct RemotePane {
  let record: ServerWorkspacePane
  let descriptor: PaneDescriptorState

  init?(_ record: ServerWorkspacePane) {
    guard let descriptor = ServerPaneMapping.descriptor(from: record) else { return nil }

    self.record = record
    self.descriptor = descriptor
  }

  var resourceKey: String? {
    guard let kind = record.resourceKind, let id = record.resourceId else { return nil }
    guard kind != "file" else { return nil }
    return "\(kind.lowercased()):\(id.lowercased())"
  }
}
