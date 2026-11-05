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
    agents(parentItems(of: workspace), isQuiet: SidebarQuietChildren.current(in: environment).contains).first
  }

  func children(of workspace: Workspace) -> [WorkspaceInspectorAgent] {
    agents(childItems(of: workspace), isQuiet: SidebarQuietChildren.current(in: environment).contains)
  }

  func pill(for workspace: Workspace) -> ChildAgentsPillContent? {
    let children = agents(childItems(of: workspace), isQuiet: { _ in true })
    guard let summary = ChildAgentsSummary(children, isWorking: isWorking) else { return nil }

    return ChildAgentsPillContent(summary: summary, agents: children, store: store)
  }

  private func isWorking(_ agent: WorkspaceInspectorAgent) -> Bool {
    switch agent.icon {
    case let .chat(session, _): store.isInProgress(session)
    case .workingTerminal: true
    case .workspace: false
    }
  }

  private func agents(_ items: [WorkspaceSidebarItem], isQuiet: (UUID) -> Bool) -> [WorkspaceInspectorAgent] {
    let content = SidebarRowContent(
      environment: environment, store: store, grouping: grouping,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let listing = SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: pinnedIDs,
      machineOrder: [], projectOrder: [])
    let navigator = SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection)
    return items.compactMap { content.listItem(for: $0) }
      .map { item in
        let workspace = item.workspace
        return WorkspaceInspectorAgent(
          id: workspace.id, name: workspace.name,
          subtitle: content.subtitle(for: workspace, isPinned: false),
          icon: content.icon(for: item, isQuiet: isQuiet(workspace.id)),
          pullRequest: content.pullRequest(for: workspace),
          machine: content.machine(for: workspace, headingNamesMachine: listing.headingNamesMachine(workspace.id))
        ) {
          revealRequest?.rowID = workspace.id
          navigator.activate(item)
        }
      }
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
