import CodevisorCore
import SwiftUI

/// The toolbar row is the sidebar toggle, the workspace's tabs, and `+`.
extension SessionContainerView {
  var tabStripItems: [WorkspaceTabStrip.Item] {
    let workspace = selectedWorkspace
    let navigation = environment.navigationStore
    let home = navigation.homeChatId(of: workspace)
    return navigation.tabStrip(for: workspace).compactMap { entry in
      guard case let .tab(tab) = entry else { return nil }
      let pane = tab.root.group(id: tab.activeLeafId)?.selectedPane ?? tab.root.allGroups.first?.state.selectedPane
      return WorkspaceTabStrip.Item(
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
        newTab: addCenterTab
      )
      // A range, not a size: the strip takes its natural width up to what
      // the row has beside the traffic lights and sidebar toggle, instead of
      // pushing itself into the toolbar's overflow menu.
      .frame(minWidth: 160, maxWidth: max(160, tabStripWidth))
    }
    .sharedBackgroundVisibility(.hidden)
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

  private func tabIcon(_ pane: PaneDescriptorState?) -> WorkspaceTabStrip.Item.Icon {
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
