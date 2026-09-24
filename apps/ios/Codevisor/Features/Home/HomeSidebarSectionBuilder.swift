import CodevisorCore
import CodevisorUI
import Foundation

/// Turns Core's precomputed sidebar -- workspaces in display order, with
/// superseded automatic workspaces removed and routing chats resolved -- into
/// the sidebar's plain section values.
///
/// Every lookup is O(1): the order and routing come from
/// `NavigationWorkspaces.sidebar`, each workspace from its own entry, and each
/// chat from `ProjectListModel.session(_:serverId:)`. Reading an entry
/// observes only that workspace.
@MainActor
struct HomeSidebarSectionBuilder {
  let environment: AppEnvironment

  func sections() -> [HomeSidebarSection] {
    let entries = environment.navigationStore.workspaceEntries
    let machines = environment.machines
    // Machines this device knows about. Their cached workspaces show at
    // launch; records from a machine that has since been removed do not.
    let knownMachineIDs = Set(machines.allMachines.map(\.id))
    let visibility = PaneNavigationVisibility()
    return entries.sidebar.compactMap { item -> HomeSidebarSection? in
      guard knownMachineIDs.contains(item.serverId),
        let workspace = entries.entry(item.id).workspace, !workspace.isArchived
      else { return nil }
      // The first routing chat that still exists anchors the workspace; a
      // terminal-only workspace routes through a closed chat Core retained.
      let anchor = item.routingChatIds.first { session($0, serverId: item.serverId) != nil }
      let rows = rows(for: workspace, visibility: visibility)
      return HomeSidebarSection(
        id: workspace.id,
        serverId: workspace.serverId,
        name: workspace.name,
        machineName: machines.fleetMachineName(for: workspace.serverId),
        anchorSessionId: anchor,
        status: rows.map(\.status).min() ?? .idle,
        rows: rows
      )
    }
  }

  private func session(_ id: UUID, serverId: String) -> ChatSession? {
    environment.projectList.session(id, serverId: serverId)
  }

  /// Navigable panes in the same order as the workspace's tab grid.
  private func rows(for workspace: Workspace, visibility: PaneNavigationVisibility) -> [HomeSidebarTabRow] {
    var seen: Set<UUID> = []
    var rows: [HomeSidebarTabRow] = []
    func append(_ pane: PaneDescriptorState, in tab: WorkspaceTab?) {
      guard visibility.includes(pane) else { return }
      guard seen.insert(pane.id).inserted else { return }
      let chat =
        pane.kind == .chat
        ? pane.chatSessionId.flatMap { session($0, serverId: workspace.serverId) }
        : nil
      rows.append(
        HomeSidebarTabRow(
          id: pane.id,
          title: tab?.displayTitle(for: pane, chatTitle: chat?.title) ?? paneTitle(pane, chat: chat),
          icon: paneIcon(pane, chat: chat),
          status: chat.map(status(for:)) ?? .idle,
          chatSessionId: chat?.id,
          renamableTabId: tab?.id
        )
      )
    }
    for tab in workspace.centerTabs {
      let groups = tab.root.allGroups
      let isSinglePane = groups.count == 1 && groups[0].state.panes.count == 1
      for group in groups {
        for pane in group.state.panes {
          append(pane, in: isSinglePane ? tab : nil)
        }
      }
    }
    return rows
  }

  private func paneTitle(_ pane: PaneDescriptorState, chat: ChatSession?) -> String {
    switch pane.kind {
    case .chat:
      let title = chat?.title ?? pane.name
      return title.isEmpty ? "New Chat" : title
    case .newTab:
      return "New Tab"
    case .browser:
      return BrowserPaneCache.shared.localTitle(paneId: pane.id) ?? pane.name
    case .terminal, .plugin, .document, .screenSharing:
      return pane.name
    }
  }

  private func paneIcon(_ pane: PaneDescriptorState, chat: ChatSession?) -> HomeSidebarTabRow.Icon {
    switch pane.kind {
    case .chat:
      .chat(
        harnessId: chat?.harnessId ?? "",
        fallbackSymbolName: chat.map(harnessSymbol(for:)) ?? "text.bubble"
      )
    case .terminal:
      .terminal(isAgentOwned: pane.attachOnly)
    case .browser:
      .browser(favicon: BrowserPaneCache.shared.favicon(paneId: pane.id))
    case .plugin:
      .plugin(pluginId: pane.pluginId ?? "", paneType: pane.pluginPaneType)
    case .document:
      .document
    case .screenSharing:
      .screenSharing
    case .newTab:
      .newTab
    }
  }

  /// Fallback SF symbol from the machine's cached capabilities, for
  /// harnesses without a bundled brand icon.
  private func harnessSymbol(for session: ChatSession) -> String {
    environment.configCache.capabilities(forServer: session.serverId)
      .first { $0.harness.id == session.harnessId }?
      .harness.symbolName ?? "cpu"
  }

  /// Classification follows the status-icon precedence (error → attention
  /// → in progress → unread), the same order the macOS sidebar uses.
  private func status(for session: ChatSession) -> HomeSessionStatus {
    if session.hasUnreadError { return .error }
    if session.actionRequired || session.pendingPlanApproval { return .actionRequired }
    if ChatControllerCache.shared.isInProgress(session) { return .inProgress }
    if session.unreadCount > 0 { return .unread }
    return .idle
  }
}
