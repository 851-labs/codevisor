import SwiftUI
import CodevisorCore

/// Each workspace is one sidebar row; its tabs live in the strip above the
/// workspace's content. Clicking a row opens the workspace on its selected
/// tab, routing through that tab's chat when it has one.
extension SidebarView {
  /// One workspace row. It reports its frame so a drag can compare the
  /// picked-up row against the others and draw the insertion line.
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
    // The picked-up row stays dimmed in place while its copy travels.
    .opacity(draggingID == id ? 0.4 : 1)
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(Self.reorderSpace))
    } action: { frame in
      recordWorkspaceFrame(frame, for: id)
    }
    .onDisappear { forgetWorkspaceGeometry(for: id) }
    // Alongside the row's own press-to-select, so a drag selects too.
    .simultaneousGesture(reorderGesture(for: id))
  }

  /// Where the workspace lives. Nil when its machine is unknown — an
  /// unresolved server isn't necessarily this one, so it stays unlabeled.
  func machineName(forServer serverId: String) -> String? {
    let machine = environment.machines.machine(for: serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  /// The workspace's machine for its row's glyph. Nil when its group
  /// heading already names the machine (grouped by machine, unless pinned)
  /// or the machine is unknown.
  func rowMachine(for workspace: Workspace) -> SidebarRowMachine? {
    guard grouping != .machine || isPinned(workspace),
      let machine = environment.machines.machine(for: workspace.serverId),
      let name = machineName(forServer: workspace.serverId)
    else { return nil }
    return SidebarRowMachine(name: name, systemImage: SidebarRowMachine.systemImage(isLocal: machine.isLocal))
  }

  /// A row's second line: the Properties menu's project, branch, and
  /// worktree, in that order, each shown whenever it is turned on and known,
  /// even when it matches the workspace's name. Only the project gives way,
  /// when the row's group heading already names it (a project folder;
  /// pinned and archived rows sit outside it).
  func rowSubtitle(for workspace: Workspace, isArchived: Bool = false) -> String? {
    let groupNamesProject = !isArchived && grouping == .project && !isPinned(workspace)
    // The logical project's name, as its folder reads: every machine's
    // record of one repository folds into one, named by the oldest.
    let projectName = ProjectGroup.grouping(list.projects).first {
      $0.contains(serverId: workspace.serverId, projectId: workspace.projectId)
    }?.name
    let parts = SidebarRowDetail.subtitleDetails.compactMap { detail -> String? in
      guard rowDetails.contains(detail) else { return nil }
      let part: String? =
        switch detail {
        case .project: groupNamesProject ? nil : projectName
        case .branch: store?.branches.byWorkspace[workspace.id]
        case .worktree: workspace.worktreeName
        default: nil
        }
      return part?.isEmpty == false ? part : nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// What the git refresh loop asks about; a change restarts it.
  struct GitLookupRefreshKey: Equatable {
    let pullRequests: Bool
    let branches: Bool
    let workspaceIds: [UUID]
  }

  /// Restarts the git refresh loop when PR badges or branches are turned on
  /// or off, or the listed workspaces change. Nil while both are off.
  var gitLookupRefreshKey: GitLookupRefreshKey? {
    let pullRequests = rowDetails.contains(.pullRequest)
    let branches = rowDetails.contains(.branch)
    guard pullRequests || branches else { return nil }
    return GitLookupRefreshKey(
      pullRequests: pullRequests, branches: branches, workspaceIds: listedSidebarItems.map(\.id)
    )
  }

  /// Asks each workspace row on screen about its pull request and branch,
  /// whichever the rows show; workspaces in collapsed groups, or without a
  /// checkout yet, are left alone.
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

  /// When the workspace last changed: its most recently updated chat, else
  /// when it was created.
  func lastUpdated(_ workspace: Workspace) -> Date {
    let chatDates = workspace.chatSessionIds.compactMap { id in
      list.session(id, serverId: workspace.serverId).map { $0.updatedAt ?? $0.createdAt }
    }
    return chatDates.max() ?? workspace.createdAt
  }

  /// The chat whose icon stands for the workspace: the one needing the
  /// most attention (an error, a question, work in progress, unread
  /// output -- the order a chat's own icon uses), else the chat in the
  /// selected tab, else the workspace's routing chat. A workspace without
  /// a chat shows a working agent terminal, or the workspace glyph.
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

  /// Whether the sidebar's selection is showing this workspace: its selected
  /// chat lives here, or the workspace itself is selected (it has no chat).
  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .newChat, .none:
      return false
    }
  }

  // MARK: - Actions

  /// Opens the workspace on the tab it last showed.
  func activateWorkspace(_ item: SidebarWorkspaceListItem) {
    guard let tab = item.workspace.selectedCenterTab ?? item.workspace.centerTabs.first else { return }
    activateTab(tab, in: item)
  }

  /// Opens one of a workspace's tabs. Selection commits synchronously before
  /// routing the workspace into the detail column, through the tab's own
  /// chat when it has one.
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

  /// ⌥⌘↑ / ⌥⌘↓, and ⇧⌘[ / ⇧⌘] while the sidebar shows: moves to the row
  /// above or below -- New Chat, then each workspace in sidebar order --
  /// stopping at either end.
  func stepWorkspace(_ offset: Int) {
    let items = listedWorkspaceItems
    let current =
      isNewChatSelected
      ? 0 : items.firstIndex { routesSelectedSession($0.workspace) }.map { $0 + 1 }
    guard let current else { return }
    let target = current + offset
    guard target != current, (0...items.count).contains(target) else { return }
    if target == 0 {
      selection = .newChat(nil)
    } else {
      let item = items[target - 1]
      activateWorkspace(item)
      revealedWorkspaceID = item.workspace.id
    }
  }

  /// The live chat a tab can route through: its selected pane's chat first,
  /// else any chat pane inside the tab's splits.
  func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    let selected = tab.root.group(id: tab.activeLeafId)?.selectedPane.map { [$0] } ?? []
    let panes = selected + tab.root.allGroups.flatMap(\.state.panes)
    for pane in panes where pane.kind == .chat {
      guard let id = pane.chatSessionId, let session = list.session(id, serverId: serverId) else { continue }
      return session
    }
    return nil
  }

  /// Applies the resolved route. A nil route means the current selection
  /// already shows this workspace and must not be disturbed.
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

  /// Adds a tab through the workspace's container, opening the workspace
  /// first when it is not the one on screen.
  func addTab(in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: .new)
    if !routesSelectedSession(workspace) {
      activateWorkspace(item)
    }
  }

  /// Archives the WORKSPACE (not just a chat): the record is flagged, its
  /// live chats archive with it, and the row leaves the list. Layout is
  /// kept — restoring any of its chats revives the whole workspace.
  private func archiveWorkspace(_ workspace: Workspace) {
    // Whether the selection lives in this workspace, decided BEFORE the
    // archive (a scratch workspace's discard also drops its session
    // index, which this lookup depends on).
    let selectionLeaves: Bool
    if case let .session(serverId, sessionId) = selection,
      serverId == workspace.serverId,
      environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    {
      selectionLeaves = true
    } else {
      selectionLeaves = false
    }
    environment.archiveWorkspace(workspace)
    pinnedWorkspaceIDs.removeAll { $0 == workspace.id.uuidString }
    if selectionLeaves {
      // Land on the most recent remaining chat; only an empty machine
      // falls through to creating a fresh scratch workspace.
      selectNextChat(serverId: workspace.serverId)
    }
  }

}
