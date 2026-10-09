import Foundation

/// A workspace's tab bar as every client shows it: its tabs with its
/// subagents' tab groups among them.
extension NavigationStore {
  public func tabStrip(for workspace: Workspace) -> [TabStripEntry] {
    let positions = SharedTabOrder.positions(of: overlaidRecords(workspace.serverId).panes, workspaceId: workspace.id)
    let owned = projection.workspaces.filter { $0.parentWorkspaceId == workspace.id && !$0.isArchived }
    let groups = owned.map { child in
      (group: tabGroup(for: child), position: child.parentTabPosition)
    }
    return TabStrip.entries(tabs: workspace.centerTabs, positions: positions, groups: groups)
  }

  /// Sends the key changes that make `entries` the tab bar order every
  /// device shows. Entries already in order keep their keys.
  public func publishTabStripOrder(of workspace: Workspace, entries: [TabStripEntry]) {
    guard workspace.isServerSynced else { return }
    let positions = SharedTabOrder.positions(of: overlaidRecords(workspace.serverId).panes, workspaceId: workspace.id)
    var groupPositions: [UUID: String] = [:]
    for case let .group(group) in entries {
      if let position = projection.workspacesById[group.workspaceId]?.parentTabPosition {
        groupPositions[group.workspaceId] = position
      }
    }
    let moves = TabStrip.moves(for: entries, positions: positions, groupPositions: groupPositions)
    guard !moves.isEmpty else { return }
    for move in moves {
      switch move {
      case let .pane(paneId, position):
        enqueueWithoutRebuild(
          .movePane(paneId: paneId, workspaceId: workspace.id, position: position), machineId: workspace.serverId)
      case let .group(workspaceId, position):
        enqueueWithoutRebuild(
          .updateWorkspaceHierarchy(workspaceId: workspaceId, change: .groupPosition(position)),
          machineId: workspace.serverId)
      }
    }
    rebuild()
    executor.resume(machineId: workspace.serverId)
  }

  /// The chat that is the workspace's own (its tab has no close button).
  public func homeChatId(of workspace: Workspace) -> UUID? {
    TabStrip.homeChatId(of: workspace, sessions: projection.sessions)
  }

  private func tabGroup(for workspace: Workspace) -> TabStripGroup {
    let home = homeChatId(of: workspace)
    let tabs = workspace.centerTabs
    let homeTab = tabs.first { !TabStrip.isClosable($0, homeChatId: home) }
    let ordered = homeTab.map { [$0] + tabs.filter { $0.id != homeTab?.id } } ?? tabs
    let chats = Set(workspace.chatSessionIds)
    let status = projection.sessions.filter { chats.contains($0.id) && $0.id == home }.map(AgentStatus.init).max()
    return TabStripGroup(
      workspaceId: workspace.id, title: workspace.name, status: status ?? .idle,
      collapsed: workspace.groupCollapsed, tabs: ordered)
  }
}
