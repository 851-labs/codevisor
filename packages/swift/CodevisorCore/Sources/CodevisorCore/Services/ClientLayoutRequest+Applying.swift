import Foundation

extension ClientLayoutRequest {
  /// Validate on a copy, then let the native owner commit once and publish
  /// any created pane through the same registry used by the UI.
  public func applying(to original: Workspace, compact: Bool) throws -> Workspace {
    guard original.id == workspaceId, !original.isArchived else {
      throw ClientControlError("Workspace is unavailable")
    }
    guard ClientCapabilities(settingsSections: [], compact: compact).layoutActions.contains(action.kind) else {
      throw ClientControlError("Layout action is unsupported on this client")
    }
    var workspace = original
    switch action.kind {
    case "new_tab":
      var state = PaneGroupState()
      _ = state.addNewTabPane()
      let tab = WorkspaceTab(root: .leaf(state))
      workspace.centerTabs.append(tab)
      workspace.selectedCenterTabId = tab.id
    case "split":
      let (index, leaf) = try source(in: workspace)
      guard let edge = action.edge else { throw ClientControlError("Missing split edge") }
      var state = PaneGroupState()
      _ = state.addNewTabPane()
      let added = UUID()
      workspace.centerTabs[index].root = workspace.centerTabs[index].root.splitting(
        groupId: leaf, edge: edge, newGroupId: added, newGroupState: state
      )
      _ = workspace.selectDestination(.leaf(added))
    case "move", "detach":
      try move(in: &workspace)
    case "resize":
      let index = try tabIndex(in: workspace)
      guard let path = action.branchPath, let fractions = action.fractions,
        let expected = action.expectedChildren,
        let branch = workspace.centerTabs[index].root.clientSplit(at: path),
        branch.children.map({ $0.node.allGroups.map(\.id) }) == expected
      else { throw ClientControlError("Split changed or is unavailable. Read client context again.") }
      guard fractions.count == branch.children.count,
        fractions.allSatisfy({ $0.isFinite && $0 > 0 }),
        abs(fractions.reduce(0, +) - 1) < 0.000001
      else { throw ClientControlError("Fractions must be positive and sum to 1") }
      workspace.centerTabs[index].root = workspace.centerTabs[index].root.replacingSplitFractions(
        at: path, with: fractions
      )
    case "reorder_tabs":
      guard let ids = action.tabIds, ids.count == workspace.centerTabs.count,
        Set(ids).count == ids.count, Set(ids) == Set(workspace.centerTabs.map(\.id))
      else { throw ClientControlError("Supply every current tab id exactly once") }
      let tabs = Dictionary(uniqueKeysWithValues: workspace.centerTabs.map { ($0.id, $0) })
      workspace.centerTabs = ids.compactMap { tabs[$0] }
    case "rename_tab":
      let index = try tabIndex(in: workspace)
      guard let title = action.title else { throw ClientControlError("Missing tab title") }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      workspace.centerTabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    default: throw ClientControlError("Unknown layout action")
    }
    return workspace
  }

  private func source(in workspace: Workspace) throws -> (Int, UUID) {
    guard let leaf = action.leafId,
      let index = workspace.centerTabs.firstIndex(where: { $0.root.group(id: leaf) != nil })
    else { throw ClientControlError("Source leaf is unavailable") }
    return (index, leaf)
  }

  private func tabIndex(in workspace: Workspace) throws -> Int {
    guard let index = workspace.centerTabs.firstIndex(where: { $0.id == action.tabId }) else {
      throw ClientControlError("Tab is unavailable")
    }
    return index
  }

  private func move(in workspace: inout Workspace) throws {
    let (index, leaf) = try source(in: workspace)
    let source = workspace.centerTabs[index]
    guard let state = source.root.group(id: leaf) else { throw ClientControlError("Leaf is unavailable") }
    if action.kind == "detach" {
      // A leaf that is already alone is already detached.
      if source.root.allGroups.count == 1 {
        _ = workspace.selectDestination(.leaf(leaf))
        return
      }
      remove(leaf: leaf, at: index, from: &workspace)
      let tab = WorkspaceTab(root: .group(id: leaf, state: state))
      workspace.centerTabs.append(tab)
      _ = workspace.selectDestination(.leaf(leaf))
      return
    }
    guard let target = action.targetLeafId, target != leaf, let edge = action.edge,
      let targetTabId = workspace.centerTabs.first(where: { $0.root.group(id: target) != nil })?.id
    else { throw ClientControlError("A different target leaf and edge are required") }
    remove(leaf: leaf, at: index, from: &workspace)
    guard let targetIndex = workspace.centerTabs.firstIndex(where: { $0.id == targetTabId }) else {
      throw ClientControlError("Target tab is unavailable")
    }
    workspace.centerTabs[targetIndex].root = workspace.centerTabs[targetIndex].root.splitting(
      groupId: target, edge: edge, newGroupId: leaf, newGroupState: state
    )
    _ = workspace.selectDestination(.leaf(leaf))
  }

  private func remove(leaf: UUID, at index: Int, from workspace: inout Workspace) {
    if let root = workspace.centerTabs[index].root.removingGroup(id: leaf) {
      workspace.centerTabs[index].root = root
      if workspace.centerTabs[index].activeLeafId == leaf, let first = root.allGroups.first?.id {
        workspace.centerTabs[index].activeLeafId = first
      }
    } else {
      workspace.centerTabs.remove(at: index)
    }
  }
}

extension SplitNode {
  func clientSplit(at path: [Int]) -> (orientation: SplitOrientation, children: [SplitChild])? {
    guard case let .split(orientation, children) = self else { return nil }
    guard let index = path.first else { return (orientation, children) }
    guard children.indices.contains(index) else { return nil }
    return children[index].node.clientSplit(at: Array(path.dropFirst()))
  }
}
