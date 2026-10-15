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

  func addCenterTab() {
    var workspace = selectedWorkspace
    var state = PaneGroupState()
    let pane = state.addNewTabPane()
    let tab = WorkspaceTab(root: .leaf(state))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    focusSelectedCenterPane()
  }

  func renameCenterTab(_ tabId: UUID, to customTitle: String?) {
    environment.workspaceSync.renameTab(
      workspaceId: selectedWorkspace.id, tabId: tabId, to: customTitle ?? ""
    )
  }

  func selectCenterTab(_ tabId: UUID) {
    store.selectDestination(.tab(tabId), in: selectedWorkspace.id)
  }

  func moveCenterTab(_ tabId: UUID, before successorId: UUID?) {
    environment.workspaceSync.moveTab(tabId, before: successorId, inWorkspace: selectedWorkspace.id)
  }

  func showsCenterTabBar(in workspace: Workspace) -> Bool {
    workspace.centerTabs.count > 1
  }

  func centerTabItems(in workspace: Workspace) -> [PaneTabStripItem] {
    workspace.centerTabs.enumerated().map { index, tab in
      let descriptor = centerTabDescriptor(tab, in: workspace)
      let title = centerTabTitle(tab, descriptor: descriptor)
      return PaneTabStripItem(
        id: tab.id,
        name: title,
        icon: .workspaceTab(
          descriptor, title: title, serverId: workspace.serverId, environment: environment, store: store),
        canClose: true,
        shortcutHint: index < 9 ? "⌘\(index + 1)" : nil
      )
    }
  }

  private func centerTabTitle(_ tab: WorkspaceTab, descriptor: PaneDescriptorState?) -> String {
    guard let descriptor else { return tab.customTitle ?? "New Tab" }
    if descriptor.kind == .chat { return paneTitle(descriptor) }
    return tab.customTitle ?? paneTitle(descriptor)
  }

  private func centerTabDescriptor(_ tab: WorkspaceTab, in workspace: Workspace) -> PaneDescriptorState? {
    let persisted = tab.root.group(id: tab.activeLeafId)
    let liveKey = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: tab.activeLeafId)
    guard var live = store.centerLeafGroups[liveKey]?.state.selectedPane else {
      return persisted?.selectedPane ?? tab.root.allGroups.first?.state.selectedPane
    }
    if let record = persisted?.panes.first(where: { $0.id == live.id }) {
      live.liveTitle = record.liveTitle
      live.terminalActivity = record.terminalActivity
    }
    return live
  }

  func closeCenterTab(_ tabId: UUID) {
    let workspace = selectedWorkspace
    guard let tab = workspace.centerTabs.first(where: { $0.id == tabId }) else { return }
    guard workspace.centerTabs.count > 1 else {
      confirmClosingWindow()
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
