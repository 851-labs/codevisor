import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
struct WorkspaceChildAgents {
  let environment: AppEnvironment
  let store: SessionStore
  let botsEnabled: Bool
  let grouping: SidebarGrouping
  let commands: WorkspaceRowCommands
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?

  func parent(of workspace: Workspace) -> WorkspaceInspectorAgent? {
    agents(parentItems(of: workspace)).first
  }

  func children(of workspace: Workspace) -> [WorkspaceInspectorAgent] {
    agents(childItems(of: workspace))
  }

  func pill(for workspace: Workspace) -> ChildAgentsPillContent? {
    let children = agents(childItems(of: workspace))
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

  private func agents(_ items: [WorkspaceSidebarItem]) -> [WorkspaceInspectorAgent] {
    let content = SidebarRowContent(
      environment: environment, store: store, grouping: grouping,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let listing = SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: commands.pinnedIDs,
      machineOrder: [], projectOrder: [])
    let tree = listing.tree
    let membership = environment.workspaceSections.membership
    return items.compactMap { item in
      guard let listItem = content.listItem(for: item) else { return nil }
      let workspace = listItem.workspace
      return WorkspaceInspectorAgent(
        id: workspace.id,
        details: content.details(
          for: listItem, isPinned: false, headingNamesMachine: listing.headingNamesMachine(workspace.id),
          isQuiet: QuietChildren.isQuiet(item)),
        actions: commands.actions(
          for: item, workspace: workspace, isPinned: commands.isPinned(workspace),
          sectionPlacement: WorkspaceSectionPlacement(workspace.id, in: tree, membership: membership))
      ) {
        open(listItem)
      }
    }
  }

  private func open(_ item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    if botsEnabled, let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) {
      selection = .bot(serverId: bot.serverId, id: bot.id)
      return
    }
    revealRequest?.rowID = workspace.id
    SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection).activate(item)
  }

  private func parentItems(of workspace: Workspace) -> [WorkspaceSidebarItem] {
    let sidebar = environment.navigationStore.workspaceEntries.sidebar
    guard let parentId = sidebar.first(where: { $0.id == workspace.id })?.parentWorkspaceId else { return [] }
    return sidebar.filter { $0.id == parentId }
  }

  private func childItems(of workspace: Workspace) -> [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.sidebar.filter { $0.parentWorkspaceId == workspace.id }
  }
}
