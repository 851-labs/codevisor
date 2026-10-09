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
      machineName: rowMachineName(forServer: workspace.serverId),
      status: status(of: workspace),
      isSelected: routesSelectedSession(workspace),
      isReordering: isReordering,
      onActivate: { activateWorkspace(item) },
      onNewTab: { addTab(in: item) },
      onRename: {
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      onArchive: { archiveWorkspace(workspace) }
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

  /// A row names its machine only when no group heading already does.
  func rowMachineName(forServer serverId: String) -> String? {
    grouping == .flat ? machineName(forServer: serverId) : nil
  }

  /// The most urgent state across the workspace's chats and agent
  /// terminals, with the same precedence as a chat's own icon.
  func status(of workspace: Workspace) -> SidebarWorkspaceStatus {
    let panes = workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
    let chats = panes.compactMap { pane -> ChatSession? in
      guard pane.kind == .chat, let id = pane.chatSessionId else { return nil }
      return list.session(id, serverId: workspace.serverId)
    }
    guard let store else {
      return panes.contains { $0.terminalAgentStatus == .working } ? .working : .idle
    }
    if chats.contains(where: store.hasUnreadError) { return .error }
    if chats.contains(where: store.isWaitingOnUser) { return .waitingOnUser }
    if chats.contains(where: store.isInProgress) || panes.contains(where: { $0.terminalAgentStatus == .working }) {
      return .working
    }
    if chats.contains(where: { store.unreadCount($0) > 0 }) { return .unread }
    return .idle
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

  /// Opens the workspace on the tab it last showed. Selection commits
  /// synchronously before routing the workspace into the detail column.
  func activateWorkspace(_ item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    guard let tab = workspace.selectedCenterTab ?? workspace.centerTabs.first,
      store?.selectDestination(.tab(tab.id), in: workspace.id) == true
    else { return }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: routableChat(in: tab, serverId: workspace.serverId)?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  /// ⌥⌘↑ / ⌥⌘↓: moves to the row above or below -- New Chat, then each
  /// workspace in sidebar order -- stopping at either end.
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
  private func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
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
    if selectionLeaves {
      // Land on the most recent remaining chat; only an empty machine
      // falls through to creating a fresh scratch workspace.
      selectNextChat(serverId: workspace.serverId)
    }
  }

}
