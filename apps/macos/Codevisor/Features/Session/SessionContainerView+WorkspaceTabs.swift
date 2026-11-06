import SwiftUI
import CodevisorCore
import CodevisorUI

extension SessionContainerView {
  func synchronizeMountedPaneGroups() {
    store.reconcileMountedPaneGroups(in: selectedWorkspace)
  }

  func activeCenterModel(in workspace: Workspace) -> PaneGroupModel {
    let leafId =
      workspace.selectedCenterTab?.resolvedActiveLeafId(preferred: activeLeafId)
      ?? workspace.centerTree.allGroups.first!.id
    return configuredCenterModel(leafId: leafId)
  }

  func focusSelectedCenterPane() {
    guard let leafId = activeLeafId else { return }
    let model = configuredCenterModel(leafId: leafId)
    sessionFocus.centerGroup = model
    model.requestSelectedPaneFocus()
  }

  var isSinglePane: Bool {
    WorkspaceLayoutPolicy.isSinglePane(selectedWorkspace, environment: environment)
  }

  func addCenterTab() {
    guard !isSinglePane else { return }
    var workspace = selectedWorkspace
    var state = PaneGroupState()
    var pane = state.addNewTabPane()
    if activeBrowserModel != nil, let browser = state.convertNewTabPane(id: pane.id, to: .browser, sessionId: nil) {
      ChromiumBrowserModels.shared.expectNewTab(browser.id, focusingAddress: true)
      pane = browser
    }
    let tab = WorkspaceTab(root: .leaf(state))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    focusSelectedCenterPane()
  }

  func keepCenterTab(_ tabId: UUID) {
    environment.workspaceSync.keepTab(workspaceId: selectedWorkspace.id, tabId: tabId)
  }

  func singlePaneChatLeaf(in workspace: Workspace) -> (id: UUID, state: PaneGroupState)? {
    guard isSinglePane, let session else { return nil }

    for tab in workspace.centerTabs {
      if let id = tab.root.groupId(containingChat: session.id), let state = tab.root.group(id: id) {
        return (id, state)
      }
    }
    return nil
  }

  func closeCenterTab(_ tabId: UUID) {
    let workspace = selectedWorkspace
    guard let tab = workspace.centerTabs.first(where: { $0.id == tabId }) else { return }
    guard workspace.centerTabs.count > 1 else {
      confirmClosingWindow()
      return
    }
    guard !workspace.holdsMainChat(tab) else {
      NSSound.beep()
      return
    }
    let panes = tab.root.allGroups.flatMap { configuredCenterModel(leafId: $0.id).state.panes }
    store.confirmClosingWorkingChats(panes, serverId: workspace.serverId) {
      closeCenterTabNow(tabId)
    }
  }

  private func closeCenterTabNow(_ tabId: UUID) {
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

    workspace = selectedWorkspace
    workspace.pruneClosedCenterTab(tabId)
    for leaf in closing.root.allGroups
    where workspace.centerTabs.allSatisfy({ $0.root.group(id: leaf.id) == nil }) {
      store.evictCenterLeaf(workspaceId: workspace.id, leafId: leaf.id)
    }
    environment.workspaces.save(workspace)
    liveCenterTree = workspace.centerTree
    if closesSelectedTab {
      activateLeaf(workspace.selectedCenterTab?.activeLeafId)
    }
  }

  func confirmClosingWindow() {
    guard let window = NSApp.keyWindow else { return }
    let alert = NSAlert()
    alert.messageText = "Close this window?"
    alert.informativeText = "Are you sure you want to close this window?"
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn { window.performClose(nil) }
    }
  }
}
