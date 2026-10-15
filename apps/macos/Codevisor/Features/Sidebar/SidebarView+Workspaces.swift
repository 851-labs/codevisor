import SwiftUI
import CodevisorCore
import CodevisorUI

extension SidebarView {
  func workspaceRow(_ item: SidebarWorkspaceListItem) -> some View {
    let workspace = item.workspace
    let id = workspace.id
    return row(
      for: workspace,
      icon: icon(for: item),
      isSelected: routesSelectedSession(workspace),
      onActivate: { activateWorkspace(item) },
      lifecycle: .active(
        isPinned: isPinned(workspace),
        onTogglePin: { togglePin(workspace) },
        onNewTab: { addTab(in: item) },
        onRename: {
          workspaceRenameTitle = workspace.name
          renamingWorkspace = workspace
        },
        onArchive: { archiveWorkspace(workspace) }
      )
    )
    .opacity(draggingID == id ? 0.4 : 1)
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(Self.reorderSpace))
    } action: { frame in
      recordWorkspaceFrame(frame, for: id)
    }
    .onDisappear { forgetWorkspaceGeometry(for: id) }
    .simultaneousGesture(reorderGesture(for: id))
  }

  func row(
    for workspace: Workspace,
    icon: SidebarWorkspaceIcon,
    isSelected: Bool,
    onActivate: @escaping () -> Void,
    lifecycle: SidebarWorkspaceRow.Lifecycle
  ) -> SidebarWorkspaceRow {
    SidebarWorkspaceRow(
      name: workspace.name,
      subtitle: rowSubtitle(for: workspace),
      icon: icon,
      store: store,
      pullRequest: rowDetails.contains(.pullRequest) ? store?.gitLookups.pullRequests.byWorkspace[workspace.id] : nil,
      machine: rowDetails.contains(.machine) ? rowMachine(for: workspace) : nil,
      isSelected: isSelected,
      isReordering: isReordering,
      onActivate: onActivate,
      lifecycle: lifecycle
    )
  }

  func isUnderGroupHeading(_ workspace: Workspace) -> Bool {
    !workspace.isArchived && !isPinned(workspace)
  }

  func machineName(forServer serverId: String) -> String? {
    let machine = environment.machines.machine(for: serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  func rowMachine(for workspace: Workspace) -> SidebarRowMachine? {
    guard grouping != .machine || !isUnderGroupHeading(workspace),
      let machine = environment.machines.machine(for: workspace.serverId),
      let name = machineName(forServer: workspace.serverId)
    else { return nil }
    return SidebarRowMachine(name: name, systemImage: machine.icon.systemImage)
  }

  func rowSubtitle(for workspace: Workspace) -> String? {
    SidebarRowSubtitle.make(
      details: rowDetails,
      projectName: ProjectGroup.grouping(list.projects).first {
        $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
      }?.name,
      branch: store?.gitLookups.branches.byWorkspace[workspace.id],
      groupNamesProject: grouping == .project && isUnderGroupHeading(workspace)
    )
  }

  var gitLookupRefreshKey: SidebarGitLookups.RefreshKey? {
    SidebarGitLookups.refreshKey(
      details: rowDetails, workspaceIds: listedSidebarItems.map(\.id) + visibleArchivedItems.map(\.id))
  }

  func refreshGitLookups() {
    store?.gitLookups.refresh(
      active: listedWorkspaceItems.map(\.workspace), archived: listedArchivedWorkspaces, details: rowDetails,
      client: environment.machines.client(for:)
    )
  }

  func icon(for item: SidebarWorkspaceListItem) -> SidebarWorkspaceIcon {
    let workspace = item.workspace
    let panes = workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
    let chats = panes.compactMap { pane -> ChatSession? in
      guard pane.kind == .chat, let id = pane.chatSessionId else { return nil }
      return list.session(id, serverId: workspace.serverId)
    }
    if let store {
      let urgent: [(ChatSession) -> Bool] = [
        store.hasUnreadError, store.isWaitingOnUser, store.isInProgress, { store.unreadCount($0) > 0 },
      ]
      for isUrgent in urgent {
        if let chat = chats.first(where: isUrgent) { return .chat(chat) }
      }
    }
    let selectedChat = workspace.selectedCenterTab.flatMap { routableChat(in: $0, serverId: workspace.serverId) }
    if let chat = selectedChat ?? item.routingSession ?? chats.first { return .chat(chat) }
    return panes.contains { $0.terminalAgentStatus == .working } ? .workingTerminal : .workspace
  }

  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .archivedWorkspace, .newChat, .none:
      return false
    }
  }

  func activateWorkspace(_ item: SidebarWorkspaceListItem) {
    guard let tab = item.workspace.selectedCenterTab ?? item.workspace.centerTabs.first else { return }
    activateTab(tab, in: item)
  }

  func activateTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    guard store?.selectDestination(.tab(tab.id), in: workspace.id) == true else { return }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: routableChat(in: tab, serverId: workspace.serverId)?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  func stepWorkspace(_ offset: Int) {
    let items = listedWorkspaceItems
    let archived = listedArchivedWorkspaces
    let current: Int? =
      if isNewChatSelected {
        0
      } else if let index = items.firstIndex(where: { routesSelectedSession($0.workspace) }) {
        index + 1
      } else if case let .archivedWorkspace(serverId, id) = selection,
        let index = archived.firstIndex(where: { $0.serverId == serverId && $0.id == id })
      {
        items.count + 1 + index
      } else {
        nil
      }
    guard let current else { return }
    let target = current + offset
    guard target != current, (0...items.count + archived.count).contains(target) else { return }
    if target == 0 {
      selection = .newChat(nil)
    } else if target <= items.count {
      let item = items[target - 1]
      activateWorkspace(item)
      revealedWorkspaceID = item.workspace.id
    } else {
      let workspace = archived[target - items.count - 1]
      selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
      revealedWorkspaceID = workspace.id
    }
  }

  func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    list.routableChat(in: tab, serverId: serverId)
  }

  private func apply(_ route: WorkspaceSelectionRoute?) {
    switch route {
    case let .session(serverId, id):
      selection = .session(serverId: serverId, id: id)
    case let .workspace(serverId, id):
      selection = .workspace(serverId: serverId, id: id)
    case nil:
      break
    }
  }

  func addTab(in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.newCenterTabRequest = NewCenterTabRequest(workspaceId: workspace.id)
    if !routesSelectedSession(workspace) {
      activateWorkspace(item)
    }
  }

  func archiveSelectedWorkspace() {
    let workspaceId: UUID? =
      switch selection {
      case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
      case let .workspace(_, id): id
      case .archivedWorkspace, .newChat, .none: nil
      }
    guard let workspace = workspaceId.flatMap({ environment.workspaces.workspace(id: $0) }),
      !workspace.isArchived
    else { return }
    archiveWorkspace(workspace)
  }

  private func archiveWorkspace(_ workspace: Workspace) {
    let selectionLeaves = routesSelectedSession(workspace)
    environment.archiveWorkspace(workspace)
    pinnedWorkspaceIDs.removeAll { $0 == workspace.id.uuidString }
    if selectionLeaves {
      selectNextChat(serverId: workspace.serverId, leaving: workspace.id)
    }
  }

}

extension ProjectListModel {
  func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    let selected = tab.root.group(id: tab.activeLeafId)?.selectedPane.map { [$0] } ?? []
    let panes = selected + tab.root.allGroups.flatMap(\.state.panes)
    for pane in panes where pane.kind == .chat {
      guard let id = pane.chatSessionId, let session = session(id, serverId: serverId) else { continue }
      return session
    }
    return nil
  }
}
