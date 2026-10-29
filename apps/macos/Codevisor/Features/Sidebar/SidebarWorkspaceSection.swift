import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceSection: View, Equatable {
  struct Actions {
    let activate: @MainActor (SidebarWorkspaceListItem) -> Void
    let togglePin: @MainActor (Workspace) -> Void
    let newTab: @MainActor (SidebarWorkspaceListItem) -> Void
    let rename: @MainActor (Workspace) -> Void
    let fork: @MainActor (ChatSession) -> Void
    let canFork: @MainActor (ChatSession) -> Bool
    let archive: @MainActor (Workspace) -> Void
    let toggleChildren: @MainActor (UUID) -> Void
  }

  let item: WorkspaceSidebarItem
  let store: SessionStore?
  let grouping: SidebarGrouping
  let rowDetails: [SidebarRowDetail]
  let isSelected: Bool
  let isPinned: Bool
  let isReordering: Bool
  let isExpanded: Bool?
  let actions: Actions
  @Environment(AppEnvironment.self) private var environment

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.store === rhs.store && lhs.grouping == rhs.grouping
      && lhs.rowDetails == rhs.rowDetails && lhs.isSelected == rhs.isSelected && lhs.isPinned == rhs.isPinned
      && lhs.isReordering == rhs.isReordering && lhs.isExpanded == rhs.isExpanded
  }

  var body: some View {
    let content = SidebarRowContent(environment: environment, store: store, grouping: grouping, rowDetails: rowDetails)
    if let listItem = content.listItem(for: item, includingArchived: true) {
      let workspace = listItem.workspace
      SidebarWorkspaceRow(
        name: workspace.name,
        subtitle: content.subtitle(for: workspace, isPinned: isPinned),
        icon: content.icon(for: listItem),
        store: store,
        pullRequest: content.pullRequest(for: workspace),
        machine: content.machine(for: workspace, isPinned: isPinned),
        isSelected: isSelected,
        isReordering: isReordering,
        isExpanded: isExpanded,
        onToggleChildren: { actions.toggleChildren(workspace.id) },
        onActivate: { actions.activate(listItem) },
        lifecycle: .active(
          isPinned: isPinned,
          onTogglePin: { actions.togglePin(workspace) },
          onNewTab: { actions.newTab(listItem) },
          onRename: { actions.rename(workspace) },
          onFork: forkAction(for: listItem.routingSession),
          onArchive: { actions.archive(workspace) }
        )
      )
    }
  }

  private func forkAction(for chat: ChatSession?) -> (() -> Void)? {
    guard let chat, actions.canFork(chat) else { return nil }
    return { actions.fork(chat) }
  }
}

@MainActor
struct SidebarRowContent {
  let environment: AppEnvironment
  let store: SessionStore?
  let grouping: SidebarGrouping
  let rowDetails: [SidebarRowDetail]

  private var list: ProjectListModel { environment.projectList }

  func listItem(for item: WorkspaceSidebarItem, includingArchived: Bool = false) -> SidebarWorkspaceListItem? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      includingArchived || !workspace.isArchived
    else { return nil }
    return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
  }

  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    list.mainChat(of: item)
  }

  func icon(for item: SidebarWorkspaceListItem) -> SidebarWorkspaceIcon {
    if let chat = item.routingSession { return .chat(chat) }
    return item.workspace.allPanes.contains { $0.terminalAgentStatus == .working } ? .workingTerminal : .workspace
  }

  func subtitle(for workspace: Workspace, isPinned: Bool) -> String? {
    SidebarRowSubtitle.make(
      details: rowDetails,
      title: workspace.name,
      projectName: projectName(for: workspace),
      branch: store?.gitLookups.branch(for: workspace),
      worktreeName: workspace.worktreeName,
      groupNamesProject: grouping == .project && isUnderGroupHeading(workspace, isPinned: isPinned)
    )
  }

  func projectName(for workspace: Workspace) -> String? {
    ProjectGroup.grouping(list.projects).first {
      $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
    }?.name
  }

  func pullRequest(for workspace: Workspace) -> ServerGitPullRequest? {
    rowDetails.contains(.pullRequest) ? store?.gitLookups.pullRequest(for: workspace) : nil
  }

  func machine(for workspace: Workspace, isPinned: Bool) -> SidebarRowMachine? {
    guard rowDetails.contains(.machine),
      grouping != .machine || !isUnderGroupHeading(workspace, isPinned: isPinned),
      let machine = environment.machines.machine(for: workspace.serverId),
      let name = machineName(forServer: workspace.serverId)
    else { return nil }
    return SidebarRowMachine(name: name, systemImage: machine.icon.systemImage)
  }

  func machineName(forServer serverId: String) -> String? {
    environment.machines.machine(for: serverId).map(Self.machineName)
  }

  static func machineName(_ machine: CodevisorMachine) -> String {
    machine.isLocal ? "This Mac" : machine.name
  }

  private func isUnderGroupHeading(_ workspace: Workspace, isPinned: Bool) -> Bool {
    !workspace.isArchived && !isPinned
  }
}
