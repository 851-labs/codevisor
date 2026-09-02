import Foundation

extension WorkspaceSyncModel {
  /// Applies a close to local workspace truth before publishing it. Pane
  /// views normally perform this mutation themselves; navigation surfaces
  /// use this path when they archive a chat without owning its live model.
  /// The final renderer becomes New Tab so an active workspace stays usable.
  func closePaneLocally(
    id: UUID,
    workspaceId: UUID,
    repository: any WorkspaceRepository,
    client: (any CodevisorServerClienting)? = nil
  ) {
    guard var workspace = repository.workspace(id: workspaceId),
      let result = workspace.closingPaneLocally(id: id)
    else { return }
    repository.save(workspace)
    noteLocalMutation()
    if let client {
      deletePane(
        id: id,
        workspaceId: workspaceId,
        optimisticReplacement: result.replacement,
        client: client
      )
    }
  }
}

private struct LocalPaneCloseResult {
  var replacement: PaneDescriptorState?
}

extension Workspace {
  fileprivate mutating func closingPaneLocally(id: UUID) -> LocalPaneCloseResult? {
    let panes =
      centerTabs.flatMap { tab in
        tab.root.allGroups.flatMap(\.state.panes)
      } + bottomGroup.panes
    if panes.count == 1, panes[0].id == id {
      let replacement = PaneDescriptorState(
        id: id,
        kind: .newTab,
        name: "New tab",
        terminalKey: id.uuidString
      )
      guard replacePane(id: id, with: replacement) else { return nil }
      return LocalPaneCloseResult(replacement: replacement)
    }
    guard removePane(id: id) else { return nil }
    pruneEmptyCenterTabs()
    ensureUsableLayout()
    return LocalPaneCloseResult(replacement: nil)
  }

  private mutating func replacePane(id: UUID, with pane: PaneDescriptorState) -> Bool {
    for tabIndex in centerTabs.indices {
      for group in centerTabs[tabIndex].root.allGroups {
        guard group.state.panes.contains(where: { $0.id == id }) else { continue }
        centerTabs[tabIndex].root = centerTabs[tabIndex].root.updatingGroup(id: group.id) {
          state in
          var state = state
          guard let index = state.panes.firstIndex(where: { $0.id == id }) else {
            return state
          }
          state.panes[index] = pane
          if state.selectedPaneId == id { state.selectedPaneId = pane.id }
          return state
        }
        return true
      }
    }
    guard let index = bottomGroup.panes.firstIndex(where: { $0.id == id }) else {
      return false
    }
    bottomGroup.panes[index] = pane
    if bottomGroup.selectedPaneId == id { bottomGroup.selectedPaneId = pane.id }
    return true
  }

  private mutating func removePane(id: UUID) -> Bool {
    var removed = false
    for tabIndex in centerTabs.indices.reversed() {
      var root = centerTabs[tabIndex].root
      for group in root.allGroups where group.state.panes.contains(where: { $0.id == id }) {
        root = root.updatingGroup(id: group.id) { state in
          var state = state
          removed = state.removePane(id: id) != nil || removed
          return state
        }
      }
      if let pruned = root.prunedEmptyGroups {
        centerTabs[tabIndex].root = pruned
      } else {
        centerTabs.remove(at: tabIndex)
      }
    }
    if bottomGroup.removePane(id: id) != nil { removed = true }
    return removed
  }

  private mutating func ensureUsableLayout() {
    guard centerTabs.isEmpty else {
      if !centerTabs.contains(where: { $0.id == selectedCenterTabId }),
        let firstId = centerTabs.first?.id
      {
        selectedCenterTabId = firstId
      }
      return
    }
    let tab = WorkspaceTab(root: .leaf(PaneGroupState()))
    centerTabs = [tab]
    selectedCenterTabId = tab.id
  }

  private mutating func pruneEmptyCenterTabs() {
    centerTabs = centerTabs.compactMap { tab in
      guard let root = tab.root.prunedEmptyGroups else { return nil }
      var tab = tab
      tab.root = root
      if root.group(id: tab.activeLeafId) == nil, let first = root.allGroups.first?.id {
        tab.activeLeafId = first
      }
      return tab
    }
  }
}
