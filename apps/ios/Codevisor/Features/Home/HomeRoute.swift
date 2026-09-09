import Foundation

/// Every destination in Home's authoritative navigation stack. New Chat is
/// deliberately absent: it is a real modal sheet until its first send creates
/// a workspace, at which point that workspace is mounted here.
enum HomeRoute: Hashable {
  /// A nil `preferredChatSessionId` restores the workspace's selected tab.
  /// Chat rows supply the chat id so that chat always wins over a
  /// previously selected terminal; non-chat tab rows supply
  /// `preferredPaneId` so the workspace opens on that exact pane.
  case workspace(
    serverId: String,
    workspaceId: UUID,
    anchorSessionId: UUID,
    preferredChatSessionId: UUID?,
    preferredPaneId: UUID? = nil
  )
}
