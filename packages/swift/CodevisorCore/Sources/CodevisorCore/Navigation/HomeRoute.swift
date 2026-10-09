import Foundation

/// Every destination in the iOS Home navigation, as Notes is built: a
/// workspace's page (`agent`) lists the workspaces nested under it and its
/// tabs, and a tab (`workspace`) is pushed from there. On a compact display
/// these are the entries of the authoritative navigation stack; on a
/// regular-width display the path is the selected workspace's page and its
/// open tab, and an empty path means New Chat.
///
/// New Chat is a route so that the same state survives a fold: on compact
/// width the sheet presentation is still used when a user taps New chat, but
/// an in-progress draft that arrives via a size-class collapse renders as a
/// pushed page rather than being lost.
public enum HomeRoute: Hashable, Sendable {
  /// A draft composer with no session yet. `serverId` is the machine the
  /// draft was requested for, nil for the fleet default.
  case newChat(serverId: String?)

  /// A workspace's page, like a Notes folder: the workspaces nested under
  /// it, then its tabs.
  case agent(serverId: String, workspaceId: UUID)

  /// A nil `preferredChatSessionId` restores the workspace's selected tab.
  /// Chat rows supply the chat id so that chat always wins over a
  /// previously selected terminal; non-chat tab rows supply
  /// `preferredPaneId` so the workspace opens on that exact pane.
  /// `preferredLeafId` names the split leaf holding that pane, so a
  /// regular-width layout activates the right column.
  case workspace(
    serverId: String,
    workspaceId: UUID,
    anchorSessionId: UUID?,
    preferredChatSessionId: UUID?,
    preferredPaneId: UUID? = nil,
    preferredLeafId: UUID? = nil
  )

  public var isNewChat: Bool {
    if case .newChat = self { return true }
    return false
  }

  /// The workspace a page or tab belongs to.
  public var workspace: (serverId: String, workspaceId: UUID)? {
    switch self {
    case .newChat: nil
    case let .agent(serverId, workspaceId): (serverId, workspaceId)
    case let .workspace(serverId, workspaceId, _, _, _, _): (serverId, workspaceId)
    }
  }

  /// The page a tab is opened from.
  public var page: HomeRoute? {
    workspace.map { .agent(serverId: $0.serverId, workspaceId: $0.workspaceId) }
  }
}
