import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct HomeSidebarSectionBuilder {
  let environment: AppEnvironment

  func sections() -> [HomeSidebarSection] {
    let entries = environment.navigationStore.workspaceEntries
    let machines = environment.machines
    let knownMachineIDs = Set(machines.allMachines.map(\.id))
    return entries.sidebar.compactMap { item -> HomeSidebarSection? in
      guard knownMachineIDs.contains(item.serverId),
        let workspace = entries.entry(item.id).workspace, !workspace.isArchived
      else { return nil }
      let anchor = item.routingChatIds.first { session($0, serverId: item.serverId) != nil }
      let rows = rows(for: workspace)
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

  private func rows(for workspace: Workspace) -> [HomeSidebarTabRow] {
    var seen: Set<UUID> = []
    var rows: [HomeSidebarTabRow] = []
    func append(_ pane: PaneDescriptorState, in tab: WorkspaceTab?, owner: WorkspaceTab) {
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
          status: chat.map(status(for:)) ?? status(forTerminal: pane),
          chatSessionId: chat?.id,
          renamableTabId: tab?.id,
          tabId: owner.id
        )
      )
    }
    for tab in workspace.centerTabs {
      let groups = tab.root.allGroups
      let isSinglePane = groups.count == 1 && groups[0].state.panes.count == 1
      for group in groups {
        for pane in group.state.panes {
          append(pane, in: isSinglePane ? tab : nil, owner: tab)
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
    case .terminal, .plugin, .document, .screenSharing, .subagent, .review, .simulator:
      return pane.displayName
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
      .terminal
    case .browser:
      .browser(favicon: BrowserPaneCache.shared.favicon(paneId: pane.id))
    case .plugin:
      .plugin(pluginId: pane.pluginId ?? "", paneType: pane.pluginPaneType)
    case .document:
      .document
    case .screenSharing:
      .screenSharing
    case .simulator:
      .simulator
    case .review:
      .review
    case .newTab:
      .newTab
    case .subagent:
      .newTab
    }
  }

  private func harnessSymbol(for session: ChatSession) -> String {
    environment.configCache.capabilities(forServer: session.serverId)
      .first { $0.harness.id == session.harnessId }?
      .harness.symbolName ?? "cpu"
  }

  private func status(for session: ChatSession) -> HomeSessionStatus {
    if session.hasUnreadError { return .error }
    if session.actionRequired || session.pendingPlanApproval { return .actionRequired }
    if ChatControllerCache.shared.isInProgress(session) { return .inProgress }
    if session.unreadCount > 0 { return .unread }
    return .idle
  }

  private func status(forTerminal pane: PaneDescriptorState) -> HomeSessionStatus {
    switch pane.terminalAgentStatus {
    case .working: .inProgress
    case .unread: .unread
    case .actionRequired: .actionRequired
    case .error: .error
    case nil: .idle
    }
  }
}
