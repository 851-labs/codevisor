import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct HomeSidebarContentBuilder {
  let environment: AppEnvironment
  let gitLookups: SidebarGitLookups

  var botEntries: [BotSidebarEntry] {
    environment.botSidebarEntries.filter { environment.machines.machine(for: $0.bot.serverId) != nil }
  }

  var listedItems: [WorkspaceSidebarItem] {
    let nested = Set(botEntries.flatMap(\.workspaceIDs))
    let botProjects = Set(environment.projectList.projects.filter(\.isBot).map(\.id))
    return known(environment.navigationStore.workspaceEntries.sidebar).filter {
      !$0.belongsToSameMachineBot && !botProjects.contains($0.projectId) && !nested.contains($0.id)
    }
  }

  var archivedItems: [WorkspaceSidebarItem] {
    let homes = Set(botEntries.map(\.bot.workspaceId))
    return known(environment.navigationStore.workspaceEntries.archived).filter { !homes.contains($0.id) }
  }

  func content(_ preferences: HomeSidebarPreferences) -> HomeSidebarContent {
    let projectGroups = ProjectGroup.grouping(environment.projectList.projects)
    var content = HomeSidebarContent.make(
      listed: listedItems,
      archived: archivedItems,
      preferences: preferences,
      projects: environment.projectList.projects,
      defaultServerId: environment.defaultComposerServerId,
      machineKey: { environment.navigationStore.machineOrderKey(forMachineId: $0, machines: environment.machines) },
      machineHeading: machineHeading
    ) { item, placement in
      guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
        workspace.isArchived == (placement == .archived)
      else { return nil }
      return sidebarWorkspace(
        workspace, item: item, preferences: preferences, projectGroups: projectGroups,
        underHeading: placement == .list)
    }
    content.canCreateBots = !environment.bots.botMachines.isEmpty
    content.bots = botEntries.map { entry in
      HomeSidebarBot(
        bot: entry.bot,
        status: environment.projectList.session(entry.bot.sessionId, serverId: entry.bot.serverId)
          .map(status(for:)) ?? .idle,
        machine: preferences.rowDetails.contains(.machine) ? rowMachine(serverId: entry.bot.serverId) : nil,
        home: environment.navigationStore.workspaceEntries.sidebar.first { $0.id == entry.bot.workspaceId }
          .flatMap { botSidebarWorkspace($0, preferences: preferences, projectGroups: projectGroups) },
        children: entry.children.compactMap {
          botSidebarWorkspace($0, preferences: preferences, projectGroups: projectGroups)
        }
      )
    }
    return content
  }

  private func botSidebarWorkspace(
    _ item: WorkspaceSidebarItem, preferences: HomeSidebarPreferences, projectGroups: [ProjectGroup]
  ) -> HomeSidebarWorkspace? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace else { return nil }
    return sidebarWorkspace(
      workspace, item: item, preferences: preferences, projectGroups: projectGroups, underHeading: false)
  }

  private func known(_ items: [WorkspaceSidebarItem]) -> [WorkspaceSidebarItem] {
    items.filter { environment.machines.machine(for: $0.serverId) != nil }
  }

  private func machineHeading(_ serverId: String) -> SidebarWorkspaceGroup.Heading {
    let machine = environment.machines.machine(for: serverId)
    return SidebarWorkspaceGroup.Heading(
      title: machine?.name ?? "Unknown Machine",
      systemImage: machine?.icon.systemImage ?? "questionmark.circle",
      newChatTarget: machine.map { NewChatTarget(machine: $0.id) }
    )
  }

  private func sidebarWorkspace(
    _ workspace: Workspace,
    item: WorkspaceSidebarItem,
    preferences: HomeSidebarPreferences,
    projectGroups: [ProjectGroup],
    underHeading: Bool
  ) -> HomeSidebarWorkspace {
    let details = preferences.rowDetails
    let rows = workspace.isArchived ? [] : rows(for: workspace)
    let projectName = projectGroups.first {
      $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
    }?.name
    return HomeSidebarWorkspace(
      id: workspace.id,
      serverId: workspace.serverId,
      name: workspace.name,
      anchorSessionId: item.routingChatIds.first { session($0, serverId: item.serverId) != nil },
      subtitle: SidebarRowSubtitle.make(
        details: details,
        title: workspace.name,
        projectName: projectName,
        branch: gitLookups.branch(for: workspace),
        worktreeName: workspace.worktreeName,
        groupNamesProject: preferences.grouping == .project && underHeading
      ),
      machine: details.contains(.machine) && !(preferences.grouping == .machine && underHeading)
        ? rowMachine(serverId: workspace.serverId) : nil,
      pullRequest: details.contains(.pullRequest) ? gitLookups.pullRequest(for: workspace) : nil,
      leadingRow: leadingRow(rows, workspace: workspace),
      primaryRowId: selectedPaneId(in: workspace),
      isPinned: preferences.pinnedIDs.contains(workspace.id.uuidString),
      isArchived: workspace.isArchived,
      rows: rows
    )
  }

  private func rowMachine(serverId: String) -> HomeSidebarRowMachine? {
    guard let machine = environment.machines.machine(for: serverId) else { return nil }
    return HomeSidebarRowMachine(name: machine.name, systemImage: machine.icon.systemImage)
  }

  private func selectedPaneId(in workspace: Workspace) -> UUID? {
    guard let tab = workspace.selectedCenterTab else { return nil }
    return tab.root.group(id: tab.activeLeafId)?.selectedPaneId
  }

  private func leadingRow(_ rows: [HomeSidebarTabRow], workspace: Workspace) -> HomeSidebarTabRow? {
    if let urgent = rows.filter({ $0.status != .idle }).min(by: { $0.status < $1.status }) { return urgent }
    let chats = rows.filter { $0.chatSessionId != nil }
    let selected = selectedPaneId(in: workspace)
    return chats.first { $0.id == selected } ?? chats.first
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
    case .terminal, .plugin, .document, .screenSharing, .subagent, .review, .simulator, .transcript:
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
    case .subagent, .transcript:
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
