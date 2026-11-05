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
    agents(parentItems(of: workspace)).first
  }

  func children(of workspace: Workspace) -> [WorkspaceInspectorAgent] {
    agents(childItems(of: workspace))
  }

  func activeChildren(of workspace: Workspace) -> [WorkspaceInspectorAgent] {
    ActiveChildAgents.select(children(of: workspace)) { activity(of: $0.icon) }
  }

  private func activity(of icon: SidebarWorkspaceIcon) -> ChildAgentActivity {
    switch icon {
    case let .chat(session, _):
      ChildAgentActivity(isWaitingOnUser: store.isWaitingOnUser(session), isWorking: store.isInProgress(session))
    case .workingTerminal:
      .working
    case .workspace:
      .idle
    }
  }

  private func agents(_ items: [WorkspaceSidebarItem]) -> [WorkspaceInspectorAgent] {
    let content = SidebarRowContent(
      environment: environment, store: store, grouping: grouping,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let listing = SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: pinnedIDs,
      machineOrder: [], projectOrder: [])
    let navigator = SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection)
    let quiet = SidebarQuietChildren.current(in: environment)
    return items.compactMap { content.listItem(for: $0) }
      .map { item in
        let workspace = item.workspace
        return WorkspaceInspectorAgent(
          id: workspace.id, name: workspace.name,
          subtitle: content.subtitle(for: workspace, isPinned: false),
          icon: content.icon(for: item, isQuiet: quiet.contains(workspace.id)),
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
