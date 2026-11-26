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

  var hasBots: Bool {
    !botEntries.isEmpty
  }

  var listedItems: [WorkspaceSidebarItem] {
    let homes = botHomes
    return known(environment.navigationStore.workspaceEntries.sidebar).filter { !homes.contains($0.id) }
  }

  var archivedItems: [WorkspaceSidebarItem] {
    let homes = botHomes
    return known(environment.navigationStore.workspaceEntries.archived).filter { !homes.contains($0.id) }
  }

  private var botHomes: Set<UUID> {
    environment.navigationStore.workspaceEntries.botHomeIds.union(botEntries.map(\.bot.workspaceId))
  }

  var botConversations: [BotConversation] {
    BotSidebarOrder.sorted(botEntries.map { conversation($0.bot) })
  }

  func content(_ preferences: HomeSidebarPreferences) -> HomeSidebarContent {
    let projectGroups = ProjectGroup.grouping(environment.projectList.projects)
    let homes = botHomes
    let archivedIDs = Set(environment.navigationStore.workspaceEntries.archived.map(\.id))
    let tree = SidebarWorkspaceTree(
      listedItems, pinnedIDs: preferences.pinnedIDs, hiddenParentIDs: homes.union(archivedIDs))
    let statuses = HomeSidebarStatusSource(environment: environment).workspaces
    var content = HomeSidebarContent.make(
      listed: tree.roots,
      children: tree.children,
      archived: archivedItems,
      preferences: preferences,
      projects: environment.projectList.projects,
      defaultServerId: environment.defaultComposerServerId,
      sections: environment.workspaceSections.sections,
      membership: environment.workspaceSections.membership,
      machineGroup: SidebarMachineGroups(
        machines: environment.machines, navigationStore: environment.navigationStore
      ).group(forServer:)
    ) { item, placement in
      guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
        workspace.isArchived == (placement == .archived)
      else { return nil }
      return sidebarWorkspace(
        workspace, item: item, preferences: preferences, projectGroups: projectGroups,
        heading: placement.heading, statuses: statuses)
    }
    content.canCreateBots = !environment.bots.botMachines.isEmpty
    let bots = botConversations.map {
      sidebarBot($0, preferences: preferences, projectGroups: projectGroups)
    }
    content.bots = bots.filter { !$0.bot.isArchived }
    content.archivedBots = bots.filter(\.bot.isArchived)
    content.botSections = environment.botSections.sections
    return content
  }

  private func sidebarBot(
    _ conversation: BotConversation, preferences: HomeSidebarPreferences, projectGroups: [ProjectGroup]
  ) -> HomeSidebarBot {
    let bot = conversation.bot
    let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId)
    return HomeSidebarBot(
      conversation: conversation,
      status: session.map(status(for:)) ?? .idle,
      machine: preferences.rowDetails.contains(.machine) ? rowMachine(serverId: bot.serverId) : nil,
      home: environment.navigationStore.workspaceEntries.sidebar.first { $0.id == bot.workspaceId }
        .flatMap { botSidebarWorkspace($0, preferences: preferences, projectGroups: projectGroups) },
      sectionID: environment.botSections.membership[bot.id]
    )
  }

  private func conversation(_ bot: Bot) -> BotConversation {
    let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId)
    return BotConversation(
      bot: bot, session: session, home: environment.home(of: bot), activity: session.map(activity(of:)) ?? .idle,
      isUnread: session?.isUnread ?? false)
  }

  private func activity(of session: ChatSession) -> BotConversation.Activity {
    if session.hasUnreadError { return .failed }
    if session.actionRequired || session.pendingPlanApproval { return .waitingOnUser }
    if ChatControllerCache.shared.isInProgress(session) { return .working }
    return .idle
  }

  private func botSidebarWorkspace(
    _ item: WorkspaceSidebarItem, preferences: HomeSidebarPreferences, projectGroups: [ProjectGroup]
  ) -> HomeSidebarWorkspace? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace else { return nil }
    return sidebarWorkspace(
      workspace, item: item, preferences: preferences, projectGroups: projectGroups, heading: nil)
  }

  func agentDetails(
    for workspace: Workspace, item: WorkspaceSidebarItem, rowDetails: [SidebarRowDetail], status: SidebarRowStatus?
  ) -> HomeSidebarRowDetails {
    var details = sidebarWorkspace(
      workspace, item: item, preferences: HomeSidebarPreferences(rowDetails: rowDetails),
      projectGroups: ProjectGroup.grouping(environment.projectList.projects), heading: nil
    ).details
    details.rowStatus = status
    return details
  }

  func agentDetails(
    for chat: ChatSession, rowDetails: [SidebarRowDetail], status: SidebarRowStatus?
  ) -> HomeSidebarRowDetails {
    let checkout = environment.navigationStore.projection.checkout(for: chat)
    let row = agentRow(for: chat)
    return HomeSidebarRowDetails(
      title: row.title,
      serverId: chat.serverId,
      subtitle: SidebarRowSubtitle.make(
        details: rowDetails,
        title: chat.title,
        projectName: projectName(of: chat),
        branch: checkout?.git.flatMap(SidebarGitLookups.head(of:)),
        worktreeName: checkout?.worktreeName,
        groupNamesProject: false
      ),
      rowStatus: status,
      showsStatusLabel: rowDetails.contains(.status),
      machine: rowDetails.contains(.machine) ? rowMachine(serverId: chat.serverId) : nil,
      pullRequest: rowDetails.contains(.pullRequest) ? checkout?.git?.pullRequest : nil,
      leadingRow: row,
      attention: row.status
    )
  }

  private func agentRow(for chat: ChatSession) -> HomeSidebarTabRow {
    HomeSidebarTabRow(
      id: chat.id,
      title: chat.title.isEmpty ? "Agent" : chat.title,
      icon: .chat(harnessId: chat.harnessId, fallbackSymbolName: harnessSymbol(for: chat)),
      status: status(for: chat),
      chatSessionId: chat.id,
      isUnread: chat.isUnread
    )
  }

  private func projectName(of chat: ChatSession) -> String? {
    ProjectGroup.grouping(environment.projectList.projects)
      .first { $0.contains(serverId: chat.serverId, projectId: chat.projectId) }?.name
  }

  private func known(_ items: [WorkspaceSidebarItem]) -> [WorkspaceSidebarItem] {
    items.filter { environment.machines.machine(for: $0.serverId) != nil }
  }

  private func sidebarWorkspace(
    _ workspace: Workspace,
    item: WorkspaceSidebarItem,
    preferences: HomeSidebarPreferences,
    projectGroups: [ProjectGroup],
    heading: SidebarWorkspaceGroup.Heading?,
    statuses: SidebarRowStatuses? = nil
  ) -> HomeSidebarWorkspace {
    let details = preferences.rowDetails
    let rowStatus = workspace.isArchived ? nil : statuses?.status(of: workspace.id)
    let rows = workspace.isArchived ? [] : rows(for: workspace)
    let projectName = projectGroups.first {
      $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
    }?.name
    let mainChatId = environment.projectList.mainChat(of: item)?.id
    return HomeSidebarWorkspace(
      id: workspace.id,
      serverId: workspace.serverId,
      name: workspace.name,
      anchorSessionId: mainChatId,
      subtitle: SidebarRowSubtitle.make(
        details: details,
        title: workspace.name,
        projectName: projectName,
        branch: gitLookups.branch(for: workspace),
        worktreeName: workspace.worktreeName,
        groupNamesProject: preferences.grouping == .project && heading != nil
      ),
      rowStatus: rowStatus,
      showsStatusLabel: details.contains(.status),
      machine: details.contains(.machine) && heading?.namesMachine != true
        ? rowMachine(serverId: workspace.serverId) : nil,
      pullRequest: details.contains(.pullRequest) ? gitLookups.pullRequest(for: workspace) : nil,
      leadingRow: leadingRow(rows, workspace: workspace, mainChatId: mainChatId),
      primaryRowId: selectedPaneId(in: workspace),
      isPinned: preferences.pinnedIDs.contains(workspace.id.uuidString),
      canPin: SidebarPins.canPin(item),
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

  private func leadingRow(
    _ rows: [HomeSidebarTabRow], workspace: Workspace, mainChatId: UUID?
  ) -> HomeSidebarTabRow? {
    if let main = mainChatId.flatMap({ id in rows.first { $0.chatSessionId == id } }) { return main }
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
    func append(_ pane: PaneDescriptorState, owner: WorkspaceTab) {
      guard seen.insert(pane.id).inserted else { return }
      let chat =
        pane.kind == .chat
        ? pane.chatSessionId.flatMap { session($0, serverId: workspace.serverId) }
        : nil
      rows.append(
        HomeSidebarTabRow(
          id: pane.id,
          title: paneTitle(pane, chat: chat, in: workspace),
          icon: paneIcon(pane, chat: chat, serverId: workspace.serverId),
          status: chat.map(status(for:)) ?? status(forTerminal: pane),
          chatSessionId: chat?.id,
          tabId: owner.id,
          isMainChat: workspace.isMainChatPane(pane),
          isUnread: chat?.isUnread ?? false
        )
      )
    }
    let mainTabId = workspace.mainTab.id
    let sessions = environment.projectList
    for tab in workspace.centerTabs
    where tab.id == mainTabId || AgentChatTabs.isListed(tab, in: workspace, sessions: sessions) {
      for group in tab.root.allGroups {
        for pane in group.state.panes {
          append(pane, owner: tab)
        }
      }
    }
    return rows
  }

  private func paneTitle(_ pane: PaneDescriptorState, chat: ChatSession?, in workspace: Workspace) -> String {
    switch pane.kind {
    case .chat:
      let title = chat.map(workspace.title(ofChat:)) ?? pane.name
      return title.isEmpty ? "New Chat" : title
    case .newTab:
      return "New Tab"
    case .browser:
      return BrowserPaneCache.shared.localTitle(paneId: pane.id) ?? pane.name
    case .terminal, .plugin, .document, .screenSharing, .subagent, .review, .simulator, .transcript:
      return pane.displayName
    }
  }

  private func paneIcon(
    _ pane: PaneDescriptorState, chat: ChatSession?, serverId: String
  ) -> HomeSidebarTabRow.Icon {
    switch pane.kind {
    case .chat:
      .chat(
        harnessId: chat?.harnessId ?? "",
        fallbackSymbolName: chat.map(harnessSymbol(for:)) ?? "text.bubble"
      )
    case .terminal:
      .terminal
    case .browser:
      .browser(favicon: pane.browserFavicon)
    case .plugin:
      .plugin(pluginId: pane.pluginId ?? "")
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
      .subagent(harnessId: pane.ownerChatSessionId.flatMap { session($0, serverId: serverId)?.harnessId } ?? "")
    case .transcript:
      .transcript
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
