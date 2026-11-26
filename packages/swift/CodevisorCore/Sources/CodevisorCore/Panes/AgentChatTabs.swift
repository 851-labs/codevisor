import Foundation

@MainActor
public enum AgentChatTabs {
  public static func listedTabIds(of workspace: Workspace, sessions: ProjectListModel) -> [UUID] {
    workspace.sideTabs.filter { isListed($0, in: workspace, sessions: sessions) }.map(\.id)
  }

  public static func isListed(_ tab: WorkspaceTab, in workspace: Workspace, sessions: ProjectListModel) -> Bool {
    tab.id == workspace.selectedCenterTabId || !holdsOnlyAgentChats(tab, in: workspace, sessions: sessions)
  }

  private static func holdsOnlyAgentChats(
    _ tab: WorkspaceTab, in workspace: Workspace, sessions: ProjectListModel
  ) -> Bool {
    let panes = tab.root.allGroups.flatMap(\.state.panes)
    guard !panes.isEmpty else { return false }
    return panes.allSatisfy { isAgentChat($0, serverId: workspace.serverId, sessions: sessions) }
  }

  private static func isAgentChat(_ pane: PaneDescriptorState, serverId: String, sessions: ProjectListModel) -> Bool {
    guard pane.kind == .chat, let chatId = pane.chatSessionId else { return false }
    return sessions.session(chatId, serverId: serverId)?.ownerAgent != nil
  }
}
