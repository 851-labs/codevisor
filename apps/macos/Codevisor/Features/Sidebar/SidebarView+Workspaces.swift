import SwiftUI
import CodevisorCore

extension SidebarView {
  func workspaceRow(_ item: SidebarWorkspaceListItem) -> some View {
    let workspace = item.workspace
    let id = workspace.id
    return SidebarWorkspaceRow(
      name: workspace.name,
      subtitle: rowSubtitle(for: workspace),
      icon: icon(for: item),
      store: store,
      updatedAt: rowDetails.contains(.updated) ? lastUpdated(item.workspace) : nil,
      pullRequest: rowDetails.contains(.pullRequest) ? store?.pullRequests.byWorkspace[id] : nil,
      machine: rowDetails.contains(.machine) ? rowMachine(for: workspace) : nil,
      isSelected: routesSelectedSession(workspace),
      isReordering: isReordering,
      onActivate: { activateWorkspace(item) },
      onNewTab: { addTab(in: item) },
      onRename: {
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      onArchive: { archiveWorkspace(workspace) },
      isPinned: isPinned(workspace),
      onTogglePin: { togglePin(workspace) }
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

  func machineName(forServer serverId: String) -> String? {
    let machine = environment.machines.machine(for: serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  func rowMachine(for workspace: Workspace) -> SidebarRowMachine? {
    guard grouping != .machine || isPinned(workspace),
      let machine = environment.machines.machine(for: workspace.serverId),
      let name = machineName(forServer: workspace.serverId)
    else { return nil }
    return SidebarRowMachine(name: name, systemImage: SidebarRowMachine.systemImage(isLocal: machine.isLocal))
  }

  func rowSubtitle(for workspace: Workspace, isArchived: Bool = false) -> String? {
    let groupNamesProject = !isArchived && grouping == .project && !isPinned(workspace)
    let projectName = ProjectGroup.grouping(list.projects).first {
      $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
    }?.name
    let parts = SidebarRowDetail.subtitleDetails.compactMap { detail -> String? in
      guard rowDetails.contains(detail) else { return nil }
      let part: String? =
        switch detail {
        case .project: groupNamesProject ? nil : projectName
        case .branch: store?.branches.byWorkspace[workspace.id]
        default: nil
        }
      return part?.isEmpty == false ? part : nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  struct GitLookupRefreshKey: Equatable {
    let pullRequests: Bool
    let branches: Bool
    let workspaceIds: [UUID]
  }

  var gitLookupRefreshKey: GitLookupRefreshKey? {
    let pullRequests = rowDetails.contains(.pullRequest)
    let branches = rowDetails.contains(.branch)
    guard pullRequests || branches else { return nil }
    return GitLookupRefreshKey(
      pullRequests: pullRequests, branches: branches, workspaceIds: listedSidebarItems.map(\.id)
    )
  }

  func refreshGitLookups() {
    guard let store else { return }
    let checkouts = listedWorkspaceItems.compactMap { item -> (id: UUID, path: String, serverId: String)? in
      guard let path = item.workspace.rootDirectory, !path.isEmpty else { return nil }
      return (item.workspace.id, path, item.workspace.serverId)
    }
    if rowDetails.contains(.pullRequest) {
      store.pullRequests.refresh(
        checkouts.map {
          .init(workspaceId: $0.id, path: $0.path, client: environment.machines.client(for: $0.serverId))
        })
    }
    if rowDetails.contains(.branch) {
      store.branches.refresh(
        checkouts.map {
          .init(workspaceId: $0.id, path: $0.path, client: environment.machines.client(for: $0.serverId))
        })
    }
  }

  func lastUpdated(_ workspace: Workspace) -> Date {
    let chatDates = workspace.chatSessionIds.compactMap { id in
      list.session(id, serverId: workspace.serverId).map { $0.updatedAt ?? $0.createdAt }
    }
    return chatDates.max() ?? workspace.createdAt
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
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: .new)
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
      selectNextChat(serverId: workspace.serverId)
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
