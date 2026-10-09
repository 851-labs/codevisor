import CodevisorCore
import SwiftUI

/// The toolbar row is the sidebar toggle, the workspace's tabs, and `+`.
extension SessionContainerView {
  /// The open workspace's tabs, in the order every device shows them.
  /// Agents it owns aren't here: they nest under it in the sidebar.
  var tabStripItems: [WorkspaceTabStripItem] {
    let workspace = selectedWorkspace
    let home = environment.navigationStore.homeChatId(of: workspace)
    return environment.navigationStore.tabStrip(for: workspace).compactMap { entry in
      guard case let .tab(tab) = entry else { return nil }
      let pane = liveDescriptor(of: tab, in: workspace)
      return WorkspaceTabStripItem(
        id: tab.id, title: tab.customTitle ?? tabTitle(pane, serverId: workspace.serverId),
        icon: tabIcon(pane, serverId: workspace.serverId),
        isSelected: workspace.selectedCenterTabId == tab.id,
        isClosable: TabStrip.isClosable(tab, homeChatId: home))
    }
  }

  func selectStripTab(_ tabId: UUID) {
    store.selectDestination(.tab(tabId), in: selectedWorkspace.id)
  }

  @ToolbarContentBuilder
  var tabStripToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      WorkspaceTabStrip(
        items: tabStripItems,
        select: selectStripTab,
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

  /// Puts a tab at `index` of the bar, on every device: in this device's
  /// layout at once, then in the shared order. Owned agents' places in the
  /// shared order (between the tabs) are kept.
  func moveCenterTab(_ id: UUID, toIndex index: Int) {
    let workspace = selectedWorkspace
    var order = tabStripItems.map(\.id).filter { $0 != id }
    order.insert(id, at: min(max(0, index), order.count))
    environment.workspaceSync.moveTab(id, toIndex: order.firstIndex(of: id) ?? index, inWorkspace: workspace.id)
    let navigation = environment.navigationStore
    guard let updated = environment.workspaces.workspace(id: workspace.id) else { return }
    let tabsById = Dictionary(updated.centerTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var reordered = order.compactMap { tabsById[$0] }[...]
    let entries = navigation.tabStrip(for: updated).map { entry -> TabStripEntry in
      guard case .tab = entry, let next = reordered.popFirst() else { return entry }
      return .tab(next)
    }
    navigation.publishTabStripOrder(of: updated, entries: entries)
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

  private func tabIcon(_ pane: PaneDescriptorState?, serverId: String) -> WorkspaceTabStripItem.Icon {
    guard let pane else { return .symbol("square.dashed") }
    if pane.kind == .browser, let favicon = store.localBrowserModel(paneId: pane.id)?.favicon {
      return .image(favicon)
    }
    if pane.kind == .chat, let chat = pane.chatSessionId,
      let session = environment.projectList.session(chat, serverId: serverId)
    {
      return .harness(session.harnessId)
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
