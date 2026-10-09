import CodevisorCore
import SwiftUI

/// The toolbar row is the sidebar toggle, the workspace's tabs, and `+`.
extension SessionContainerView {
  /// The agent whose tab bar this window shows: the selected workspace's
  /// top-level owner, so a subagent's tabs appear as a group in the bar of
  /// the agent that owns it.
  var tabStripRoot: Workspace {
    var workspace = selectedWorkspace
    var seen: Set<UUID> = [workspace.id]
    while let parentId = workspace.parentWorkspaceId, seen.insert(parentId).inserted,
      let parent = environment.workspaces.workspace(id: parentId), !parent.isArchived
    {
      workspace = parent
    }
    return workspace
  }

  var tabStripItems: [WorkspaceTabStripItem] {
    let root = tabStripRoot
    let current = selectedWorkspace
    let navigation = environment.navigationStore
    return navigation.tabStrip(for: root).flatMap { entry -> [WorkspaceTabStripItem] in
      switch entry {
      case let .tab(tab):
        return [tabItem(tab, in: root, current: current)]
      case let .group(group):
        let color = Self.groupColor(group.workspaceId)
        let chip = WorkspaceTabStripItem(
          id: group.workspaceId, title: group.title, icon: .symbol("person.2"), isSelected: false,
          isClosable: false, kind: .group(status: group.status, collapsed: group.collapsed),
          workspaceId: group.workspaceId, groupColor: color)
        guard !group.collapsed, let child = environment.workspaces.workspace(id: group.workspaceId) else {
          return [chip]
        }
        return [chip]
          + group.tabs.map { tab in
            var item = tabItem(tab, in: child, current: current)
            item.groupColor = color
            item.isMovable = false
            return item
          }
      }
    }
  }

  private func tabItem(_ tab: WorkspaceTab, in workspace: Workspace, current: Workspace) -> WorkspaceTabStripItem {
    let isCurrent = workspace.id == current.id
    let pane = liveDescriptor(of: tab, in: workspace)
    let home = environment.navigationStore.homeChatId(of: workspace)
    return WorkspaceTabStripItem(
      id: tab.id, title: tab.customTitle ?? tabTitle(pane, serverId: workspace.serverId),
      icon: tabIcon(pane), isSelected: isCurrent && workspace.selectedCenterTabId == tab.id,
      // Tabs of a workspace this window isn't showing close from there.
      isClosable: isCurrent && TabStrip.isClosable(tab, homeChatId: home),
      workspaceId: workspace.id)
  }

  /// A group's color, stable for the workspace on every device.
  static func groupColor(_ id: UUID) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint]
    let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
    return palette[sum % palette.count]
  }

  /// Selects a tab of the bar, showing its workspace when it is another
  /// one (a subagent's group, or the owner from inside a subagent).
  func selectStripTab(_ tabId: UUID) {
    guard let item = tabStripItems.first(where: { $0.id == tabId }),
      let workspaceId = item.workspaceId
    else { return }
    if case .group = item.kind { return }
    guard store.selectDestination(.tab(tabId), in: workspaceId), workspaceId != selectedWorkspace.id,
      let workspace = environment.workspaces.workspace(id: workspaceId),
      let tab = workspace.centerTabs.first(where: { $0.id == tabId })
    else { return }
    let chat = tab.root.allGroups.compactMap { $0.state.selectedPane?.chatSessionId }.first
    store.routeRequest =
      chat.map { .session(serverId: workspace.serverId, id: $0) }
      ?? .workspace(serverId: workspace.serverId, id: workspace.id)
  }

  func toggleStripGroup(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .groupCollapsed(!workspace.groupCollapsed)),
      machineId: workspace.serverId)
  }

  func promoteStripGroup(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.navigationStore.enqueue(
      .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .owner(nil)), machineId: workspace.serverId)
  }

  func archiveStripGroup(_ workspaceId: UUID) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    environment.archiveWorkspace(workspace)
  }

  @ToolbarContentBuilder
  var tabStripToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      WorkspaceTabStrip(
        items: tabStripItems,
        select: selectStripTab,
        close: closeCenterTab,
        closeOthers: closeOtherCenterTabs,
        move: moveCenterTab,
        toggleGroup: toggleStripGroup,
        promoteGroup: promoteStripGroup,
        archiveGroup: archiveStripGroup
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

  /// Puts a tab or group at `index` of the bar, on every device. A tab moves
  /// in this device's layout at once, then the bar's shared keys follow so
  /// subagent groups keep their places around it.
  func moveCenterTab(_ id: UUID, toIndex index: Int) {
    let root = tabStripRoot
    let navigation = environment.navigationStore
    // Items include an expanded group's tabs; entries count only the bar's
    // own tabs and the groups.
    let items = tabStripItems.filter { $0.id != id }
    let entryIndex = items.prefix(index).filter(\.isMovable).count
    var entries = navigation.tabStrip(for: root)
    guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
    let entry = entries.remove(at: from)
    entries.insert(entry, at: min(max(0, entryIndex), entries.count))
    if case .tab = entry {
      let tabs = entries.compactMap { entry -> UUID? in
        if case let .tab(tab) = entry { return tab.id }
        return nil
      }
      if let target = tabs.firstIndex(of: id) {
        environment.workspaceSync.moveTab(id, toIndex: target, inWorkspace: root.id)
      }
    }
    guard let updated = environment.workspaces.workspace(id: root.id) else { return }
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
