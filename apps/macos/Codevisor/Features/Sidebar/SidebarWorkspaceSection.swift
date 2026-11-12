import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceSection: View, Equatable {
  struct Actions {
    let activate: @MainActor (SidebarWorkspaceListItem) -> Void
    let openAsking: @MainActor (SidebarWorkspaceListItem) -> Void
    let commands: WorkspaceRowCommands
  }

  let item: WorkspaceSidebarItem
  let store: SessionStore?
  let grouping: SidebarGrouping
  let rowDetails: [SidebarRowDetail]
  var status: SidebarRowStatus? = nil
  let isSelected: Bool
  let isPinned: Bool
  let headingNamesMachine: Bool
  let isReordering: Bool
  let sectionPlacement: WorkspaceSectionPlacement?
  let sections: [CustomSection]
  let actions: Actions
  @Environment(AppEnvironment.self) private var environment

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.store === rhs.store && lhs.grouping == rhs.grouping
      && lhs.rowDetails == rhs.rowDetails && lhs.status == rhs.status && lhs.isSelected == rhs.isSelected
      && lhs.isPinned == rhs.isPinned
      && lhs.headingNamesMachine == rhs.headingNamesMachine && lhs.isReordering == rhs.isReordering
      && lhs.sectionPlacement == rhs.sectionPlacement
      && lhs.sections == rhs.sections
  }

  var body: some View {
    let content = SidebarRowContent(environment: environment, store: store, grouping: grouping, rowDetails: rowDetails)
    if let listItem = content.listItem(for: item, includingArchived: true) {
      let workspace = listItem.workspace
      SidebarWorkspaceRow(
        details: content.details(
          for: listItem, isPinned: isPinned, headingNamesMachine: headingNamesMachine, status: status),
        store: store,
        isSelected: isSelected,
        isReordering: isReordering,
        onActivate: { activate(listItem, content: content) },
        lifecycle: .active(
          actions.commands.actions(
            for: item, workspace: workspace, isPinned: isPinned, sectionPlacement: sectionPlacement))
      )
    }
  }

  private func activate(_ listItem: SidebarWorkspaceListItem, content: SidebarRowContent) {
    guard let asker = askingItem(content: content) else { return actions.activate(listItem) }
    actions.openAsking(asker)
  }

  private func askingItem(content: SidebarRowContent) -> SidebarWorkspaceListItem? {
    guard let askingID = status?.askingWorkspaceID, askingID != item.id else { return nil }
    let source = SidebarRowStatusSource(environment: environment, store: store)
    return source.item(askingID).flatMap { content.listItem(for: $0) }
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

  func icon(for item: SidebarWorkspaceListItem, isQuiet: Bool = false) -> SidebarWorkspaceIcon {
    if let chat = item.routingSession { return .chat(chat, isQuiet: isQuiet) }
    return item.workspace.allPanes.contains { $0.terminalAgentStatus == .working } ? .workingTerminal : .workspace
  }

  func details(
    for item: SidebarWorkspaceListItem, isPinned: Bool, headingNamesMachine: Bool, isQuiet: Bool = false,
    status: SidebarRowStatus? = nil
  ) -> WorkspaceRowDetails {
    let workspace = item.workspace
    return WorkspaceRowDetails(
      name: workspace.name,
      subtitle: subtitle(for: workspace, isPinned: isPinned),
      status: status,
      icon: icon(for: item, isQuiet: isQuiet),
      pullRequest: pullRequest(for: workspace),
      machine: machine(for: workspace, headingNamesMachine: headingNamesMachine)
    )
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

  func machine(for workspace: Workspace, headingNamesMachine: Bool) -> SidebarRowMachine? {
    guard rowDetails.contains(.machine), !headingNamesMachine,
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
