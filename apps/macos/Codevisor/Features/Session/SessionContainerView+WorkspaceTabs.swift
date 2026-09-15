import SwiftUI
import CodevisorCore
import CodevisorUI

// MARK: - WorkspaceTabs

extension SessionContainerView {
  /// Workspace sync writes reconciled descriptors into the repository.
  /// Mounted pane models retain live views and focus, so explicitly adopt
  /// that content identity instead of leaving their creation-time snapshot
  /// in front of repository truth.
  func synchronizeMountedPaneGroups() {
    let workspace = selectedWorkspace
    if store.reconcileMountedPaneGroups(in: workspace) {
      workspaceRevision += 1
    }
  }

  func activeCenterModel(in workspace: Workspace) -> PaneGroupModel {
    let leafId =
      workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId)
      ?? workspace.centerTree.allGroups.first!.id
    return configuredCenterModel(leafId: leafId)
  }

  /// A sidebar-originated tab action for this workspace.
  func performCenterTabRequest(_ request: CenterTabRequest) {
    switch request.action {
    case let .close(tabId): closeCenterTab(tabId)
    case .new: addCenterTab()
    case let .closeLeaf(leafId): closeLeaf(leafId)
    }
  }

  func selectCenterTab(_ tabId: UUID) {
    let workspace = selectedWorkspace
    store.selectDestination(.tab(tabId), in: workspace.id)
  }

  /// Focus follows committed navigation. A delayed callback from an earlier
  /// click must never activate its old tab or steal the new pane's focus.
  func focusSelectedCenterPane() {
    guard let leafId = activeLeafId else { return }
    let model = configuredCenterModel(leafId: leafId)
    sessionFocus.centerGroup = model
    model.requestSelectedPaneFocus()
  }

  func addCenterTab() {
    var workspace = selectedWorkspace
    if let current = workspace.selectedCenterTab {
      rememberWorkspaceDefaults(
        fromLeaf: activeLeafId ?? current.activeLeafId,
        in: workspace
      )
    }
    var state = PaneGroupState()
    let pane = state.addNewTabPane()
    let tab = WorkspaceTab(root: .leaf(state))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    // The New Tab page mounts a tick later; the group replays this focus
    // request into its picker once the page registers.
    focusSelectedCenterPane()
  }

  func renameCenterTab(_ tabId: UUID, to customTitle: String?) {
    environment.workspaceSync.renameTab(
      workspaceId: selectedWorkspace.id, tabId: tabId,
      chatSessionId: activePaneDescriptor?.chatSessionId, to: customTitle ?? ""
    )
  }

  func closeCenterTab(_ tabId: UUID) {
    var workspace = selectedWorkspace
    guard let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
    let closing = workspace.centerTabs[index]
    let closesSelectedTab = workspace.selectedCenterTabId == tabId
    closingCenterTabId = tabId
    for leaf in closing.root.allGroups {
      let model = configuredCenterModel(leafId: leaf.id)
      for paneId in model.state.panes.map(\.id) {
        model.closePane(id: paneId, activateRemainingPane: closesSelectedTab)
      }
    }
    closingCenterTabId = nil

    // Re-read after the models persisted their mutations. When closing
    // this tab would close the workspace's final pane, that pane has been
    // converted in place and the tab remains. Otherwise empty leaves and
    // the now-empty layout tab are purely local cleanup.
    workspace = selectedWorkspace
    workspace.pruneClosedCenterTab(tabId)
    for leaf in closing.root.allGroups
    where workspace.centerTabs.allSatisfy({ $0.root.group(id: leaf.id) == nil }) {
      store.evictCenterLeaf(workspaceId: workspace.id, leafId: leaf.id)
    }
    environment.workspaces.save(workspace)
    workspaceRevision += 1
    liveCenterTree = workspace.centerTree
    if closesSelectedTab {
      activateLeaf(workspace.selectedCenterTab?.activeLeafId)
    }
  }
}
