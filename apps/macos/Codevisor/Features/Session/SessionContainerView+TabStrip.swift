import CodevisorCore
import SwiftUI

/// The toolbar row is the sidebar toggle, the workspace's tabs, and `+`.
extension SessionContainerView {
  var tabStripItems: [WorkspaceTabStripItem] {
    let workspace = selectedWorkspace
    let navigation = environment.navigationStore
    let home = navigation.homeChatId(of: workspace)
    return navigation.tabStrip(for: workspace).compactMap { entry in
      guard case let .tab(tab) = entry else { return nil }
      let pane = liveDescriptor(of: tab, in: workspace)
      return WorkspaceTabStripItem(
        id: tab.id, title: tab.customTitle ?? tabTitle(pane, serverId: workspace.serverId),
        icon: tabIcon(pane), isSelected: workspace.selectedCenterTabId == tab.id,
        isClosable: TabStrip.isClosable(tab, homeChatId: home))
    }
  }

  @ToolbarContentBuilder
  var tabStripToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      WorkspaceTabStrip(
        items: tabStripItems,
        select: { store.selectDestination(.tab($0), in: selectedWorkspace.id) },
        close: closeCenterTab,
        closeOthers: closeOtherCenterTabs,
        move: moveCenterTab
      ) {
        NewTabMenu(isPresented: $newTabMenuPresented, machineId: selectedWorkspace.serverId, open: openNewTab)
      }
      // A range, not a size: the strip takes its natural width up to what
      // the row has beside the traffic lights and sidebar toggle, instead of
      // pushing itself into the toolbar's overflow menu.
      .frame(minWidth: 160, maxWidth: max(160, tabStripWidth))
    }
    .sharedBackgroundVisibility(.hidden)
  }

  /// Puts a tab at `index` of the strip, on every device. The tab moves in
  /// this device's layout at once, then the strip's shared keys follow so
  /// subagent groups keep their places around it.
  func moveCenterTab(_ tabId: UUID, toIndex index: Int) {
    let workspace = selectedWorkspace
    let navigation = environment.navigationStore
    var entries = navigation.tabStrip(for: workspace)
    guard let from = entries.firstIndex(where: { $0.id == tabId }) else { return }
    let entry = entries.remove(at: from)
    entries.insert(entry, at: min(max(0, index), entries.count))
    let tabs = entries.compactMap { entry -> UUID? in
      if case let .tab(tab) = entry { return tab.id }
      return nil
    }
    if let target = tabs.firstIndex(of: tabId) {
      environment.workspaceSync.moveTab(tabId, toIndex: target, inWorkspace: workspace.id)
    }
    navigation.publishTabStripOrder(of: selectedWorkspace, entries: entries)
  }

  /// Opens what the `+` popover chose in a new tab at the end of the bar.
  func openNewTab(_ option: NewTabOption) {
    let (leafId, paneId) = appendNewTabPlaceholder()
    let model = configuredCenterModel(leafId: leafId)
    option.open(paneId: paneId, in: model) { [weak model] in
      createChat(convertingPlaceholder: paneId, in: model)
    }
    focusSelectedCenterPane()
  }

  func closeOtherCenterTabs(_ keptTabId: UUID) {
    let workspace = selectedWorkspace
    let home = environment.navigationStore.homeChatId(of: workspace)
    for tab in workspace.centerTabs where tab.id != keptTabId && TabStrip.isClosable(tab, homeChatId: home) {
      closeCenterTab(tab.id)
    }
  }

  /// The pane that names a tab: its active leaf's selected pane. A mounted
  /// leaf's live model runs ahead of the repository mid-edit (a page that
  /// just loaded), so prefer it.
  private func liveDescriptor(of tab: WorkspaceTab, in workspace: Workspace) -> PaneDescriptorState? {
    let key = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: tab.activeLeafId)
    return store.centerLeafGroups[key]?.state.selectedPane
      ?? tab.root.group(id: tab.activeLeafId)?.selectedPane ?? tab.root.allGroups.first?.state.selectedPane
  }

  private func tabTitle(_ pane: PaneDescriptorState?, serverId: String) -> String {
    guard let pane else { return "New Tab" }
    if pane.kind == .chat, let id = pane.chatSessionId,
      let session = environment.projectList.session(id, serverId: serverId)
    {
      return session.title
    }
    if pane.kind == .browser, let title = store.localBrowserTitle(paneId: pane.id) { return title }
    return pane.displayName
  }

  private func tabIcon(_ pane: PaneDescriptorState?) -> WorkspaceTabStripItem.Icon {
    guard let pane else { return .symbol("square.dashed") }
    if pane.kind == .browser, let favicon = store.localBrowserModel(paneId: pane.id)?.favicon {
      return .image(favicon)
    }
    return switch pane.kind {
    case .chat: .symbol("text.bubble")
    case .terminal: .symbol(pane.attachOnly ? "server.rack" : "terminal")
    case .browser: .symbol("globe")
    case .review: .symbol("plusminus")
    case .simulator: .symbol("iphone")
    case .screenSharing: .symbol("display")
    case .document: .symbol("doc")
    case .subagent: .symbol("person.2")
    case .plugin: .symbol("puzzlepiece.extension")
    case .newTab: .symbol("square.dashed")
    }
  }
}
