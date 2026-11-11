import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
struct WorkspaceChildAgents {
  let environment: AppEnvironment
  let store: SessionStore
  let botsEnabled: Bool
  let grouping: SidebarGrouping
  let pinnedIDs: [String]
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func parent(of workspace: Workspace) -> WorkspaceInspectorAgent? {
    agents(parentItems(of: workspace), openingIn: nil).first
  }

  func children(of workspace: Workspace) -> [WorkspaceInspectorAgent] {
    agents(childItems(of: workspace), openingIn: workspace)
  }

  func pill(for workspace: Workspace) -> ChildAgentsPillContent? {
    let children = agents(childItems(of: workspace), openingIn: workspace)
    guard let summary = ChildAgentsSummary(children, isWorking: isWorking, harnessId: harnessId) else { return nil }

    return ChildAgentsPillContent(summary: summary, agents: children, store: store)
  }

  private func isWorking(_ agent: WorkspaceInspectorAgent) -> Bool {
    switch agent.icon {
    case let .chat(session, _): store.isInProgress(session)
    case .workingTerminal: true
    case .workspace: false
    }
  }

  private func harnessId(_ agent: WorkspaceInspectorAgent) -> String? {
    guard case let .chat(session, _) = agent.icon else { return nil }
    return session.harnessId
  }

  private func agents(_ items: [WorkspaceSidebarItem], openingIn host: Workspace?) -> [WorkspaceInspectorAgent] {
    let content = SidebarRowContent(
      environment: environment, store: store, grouping: grouping,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let listing = SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: pinnedIDs,
      machineOrder: [], projectOrder: [])
    return items.compactMap { item in
      guard let listItem = content.listItem(for: item) else { return nil }
      let workspace = listItem.workspace
      let isQuiet = QuietChildren.isQuiet(item)
      return WorkspaceInspectorAgent(
        id: workspace.id, name: workspace.name,
        subtitle: content.subtitle(for: workspace, isPinned: false),
        icon: content.icon(for: listItem, isQuiet: isQuiet),
        pullRequest: content.pullRequest(for: workspace),
        machine: content.machine(for: workspace, headingNamesMachine: listing.headingNamesMachine(workspace.id))
      ) {
        open(listItem, splittingInto: isQuiet ? host : nil)
      }
    }
  }

  private func open(_ item: SidebarWorkspaceListItem, splittingInto host: Workspace?) {
    if let host, let request = splitRequest(for: item, in: host) {
      store.childAgentSplitRequest = request
      return
    }
    revealRequest?.rowID = item.workspace.id
    SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection).activate(item)
  }

  private func splitRequest(for item: SidebarWorkspaceListItem, in host: Workspace) -> ChildAgentSplitRequest? {
    guard let chat = item.routingSession, canSplit(host) else { return nil }
    return ChildAgentSplitRequest(workspaceId: host.id, chatSessionId: chat.id, name: item.workspace.name)
  }

  private func canSplit(_ host: Workspace) -> Bool {
    store.navigationWorkspaceId == host.id
  }

  private func parentItems(of workspace: Workspace) -> [WorkspaceSidebarItem] {
    let sidebar = environment.navigationStore.workspaceEntries.sidebar
    guard let parentId = sidebar.first(where: { $0.id == workspace.id })?.parentWorkspaceId else { return [] }
    return sidebar.filter { $0.id == parentId }
  }

  private func childItems(of workspace: Workspace) -> [WorkspaceSidebarItem] {
    let children = environment.navigationStore.workspaceEntries.sidebar.filter { $0.parentWorkspaceId == workspace.id }
    guard let bot = bot(of: workspace) else { return children }

    let botChildren = environment.botSidebarEntries.first { $0.bot.id == bot.id }?.children ?? []
    let listed = Set(botChildren.map(\.id))
    return botChildren + children.filter { !listed.contains($0.id) }
  }

  private func bot(of workspace: Workspace) -> Bot? {
    guard botsEnabled else { return nil }
    return environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId)
  }
}
