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
    let archive: @MainActor (Workspace) -> Void
  }

  let item: WorkspaceSidebarItem
  let store: SessionStore?
  let grouping: SidebarGrouping
  let rowDetails: [SidebarRowDetail]
  let isSelected: Bool
  let isPinned: Bool
  let isReordering: Bool
  let actions: Actions
  @Environment(AppEnvironment.self) private var environment

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.store === rhs.store && lhs.grouping == rhs.grouping
      && lhs.rowDetails == rhs.rowDetails && lhs.isSelected == rhs.isSelected && lhs.isPinned == rhs.isPinned
      && lhs.isReordering == rhs.isReordering
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
        onActivate: { actions.activate(listItem) },
        lifecycle: .active(
          isPinned: isPinned,
          onTogglePin: { actions.togglePin(workspace) },
          onNewTab: { actions.newTab(listItem) },
          onRename: { actions.rename(workspace) },
          onArchive: { actions.archive(workspace) }
        )
      )
    }
  }
}

@MainActor
struct SidebarChatStatus {
  let list: ProjectListModel
  let store: SessionStore?

  func chats(in workspace: Workspace) -> [ChatSession] {
    workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }.compactMap { pane in
      guard pane.kind == .chat, let id = pane.chatSessionId else { return nil }
      return list.session(id, serverId: workspace.serverId)
    }
  }

  func urgentChat(among chats: [ChatSession]) -> ChatSession? {
    guard let store else { return nil }
    let urgent: [(ChatSession) -> Bool] = [
      store.hasUnreadError, store.isWaitingOnUser, store.isInProgress, { store.unreadCount($0) > 0 },
    ]
    for isUrgent in urgent {
      if let chat = chats.first(where: isUrgent) { return chat }
    }
    return nil
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
    var fallback: ChatSession?
    for id in item.routingChatIds {
      guard let session = list.session(id, serverId: item.serverId) else { continue }
      if session.origin == .codevisor || list.showsImportedSessions { return session }
      if fallback == nil { fallback = session }
    }
    return fallback
  }

  func icon(for item: SidebarWorkspaceListItem) -> SidebarWorkspaceIcon {
    let workspace = item.workspace
    let status = SidebarChatStatus(list: list, store: store)
    let chats = status.chats(in: workspace)
    if let chat = status.urgentChat(among: chats) { return .chat(chat) }
    let panes = workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
    let selectedChat = workspace.selectedCenterTab.flatMap { list.routableChat(in: $0, serverId: workspace.serverId) }
    if let chat = selectedChat ?? item.routingSession ?? chats.first { return .chat(chat) }
    return panes.contains { $0.terminalAgentStatus == .working } ? .workingTerminal : .workspace
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
