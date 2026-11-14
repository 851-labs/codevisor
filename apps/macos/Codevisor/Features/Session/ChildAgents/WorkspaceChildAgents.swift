import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
struct WorkspaceChildAgents {
  let environment: AppEnvironment
  let store: SessionStore
  let commands: WorkspaceRowCommands
  let renameChat: @MainActor (ChatSession) -> Void
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func parent(of chat: ChatSession) -> WorkspaceInspectorAgent? {
    agents(environment.projectList.parent(of: chat).map { [$0] } ?? []).first
  }

  func children(of chat: ChatSession) -> [WorkspaceInspectorAgent] {
    agents(environment.projectList.children(of: chat))
  }

  func pill(for chat: ChatSession) -> ChildAgentsPillContent? {
    let children = children(of: chat)
    guard let summary = ChildAgentsSummary(children, isWorking: isWorking, harnessId: harnessId) else { return nil }

    return ChildAgentsPillContent(summary: summary, agents: children, store: store)
  }

  private func isWorking(_ agent: WorkspaceInspectorAgent) -> Bool {
    switch agent.details.icon {
    case let .chat(session, _): store.isInProgress(session)
    case .workingTerminal: true
    case .workspace: false
    }
  }

  private func harnessId(_ agent: WorkspaceInspectorAgent) -> String? {
    guard case let .chat(session, _) = agent.details.icon else { return nil }
    return session.harnessId
  }

  private func agents(_ chats: [ChatSession]) -> [WorkspaceInspectorAgent] {
    guard !chats.isEmpty else { return [] }

    let content = SidebarRowContent(
      environment: environment, store: store, grouping: .flat,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let statuses = SidebarRowStatusSource(environment: environment, store: store)
    return chats.map { chat in
      let status = statuses.status(of: chat)
      if environment.bots.bot(forSession: chat.id, serverId: chat.serverId) != nil {
        return WorkspaceInspectorAgent(
          id: chat.id, details: content.details(for: chat, status: status), lifecycle: .fixed
        ) {
          open(chat)
        }
      }
      if let item = ownItem(of: chat), let listItem = content.listItem(for: item) {
        return workspaceAgent(chat, item: item, listItem: listItem, content: content, status: status)
      }
      return chatAgent(chat, details: content.details(for: chat, status: status))
    }
  }

  private func ownItem(of chat: ChatSession) -> WorkspaceSidebarItem? {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: chat.id) else { return nil }
    let item = environment.navigationStore.workspaceEntries.sidebar.first {
      $0.id == workspaceId && $0.serverId == chat.serverId
    }
    return item.flatMap { environment.projectList.mainChat(of: $0)?.id == chat.id ? $0 : nil }
  }

  private func workspaceAgent(
    _ chat: ChatSession, item: WorkspaceSidebarItem, listItem: SidebarWorkspaceListItem, content: SidebarRowContent,
    status: SidebarRowStatus?
  ) -> WorkspaceInspectorAgent {
    let workspace = listItem.workspace
    let listing = SidebarWorkspaceListing(
      environment: environment, grouping: .flat, pinnedIDs: commands.pinnedIDs, machineOrder: [], projectOrder: [])
    return WorkspaceInspectorAgent(
      id: chat.id,
      details: content.details(
        for: listItem, isPinned: false, headingNamesMachine: false, isQuiet: chat.createdByAgent != nil,
        status: status),
      lifecycle: .active(
        commands.actions(
          for: item, workspace: workspace, isPinned: commands.isPinned(workspace),
          sectionPlacement: WorkspaceSectionPlacement(
            workspace.id, in: listing.tree, membership: environment.workspaceSections.membership)))
    ) {
      open(listItem, showing: chat)
    }
  }

  private func chatAgent(_ chat: ChatSession, details: WorkspaceRowDetails) -> WorkspaceInspectorAgent {
    let actions = WorkspaceRowActions(
      pin: nil, rename: { renameChat(chat) }, archive: { archive(chat) }, noun: "agent")
    return WorkspaceInspectorAgent(id: chat.id, details: details, lifecycle: .active(actions)) {
      open(chat)
    }
  }

  private func open(_ item: SidebarWorkspaceListItem, showing chat: ChatSession) {
    let workspace = item.workspace
    if let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) {
      environment.botThreads.closePage(of: bot)
      selection = .bot(serverId: bot.serverId, id: bot.id)
      return
    }
    revealRequest?.rowID = workspace.id
    SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection)
      .activate(item, tabId: workspace.tabId(containingChat: chat.id))
  }

  private func open(_ chat: ChatSession) {
    if let bot = environment.bots.bot(forSession: chat.id, serverId: chat.serverId) {
      selection = .bot(serverId: bot.serverId, id: bot.id)
      return
    }
    if let host = environment.botShowing(chat) {
      environment.botThreads.showAgent(chat.id, of: host)
      selection = .bot(serverId: host.serverId, id: host.id)
      return
    }
    selection = store.selectChat(chat)
  }

  private func archive(_ chat: ChatSession) {
    let client = environment.machines.client(for: chat.serverId)
    Task { try? await client.archiveAgent(id: chat.id) }
  }
}
