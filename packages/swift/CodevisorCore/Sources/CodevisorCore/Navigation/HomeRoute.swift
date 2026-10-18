import Foundation

public enum HomeRoute: Hashable, Sendable {
  case newChat(serverId: String?)

  case workspace(
    serverId: String,
    workspaceId: UUID,
    anchorSessionId: UUID?,
    preferredChatSessionId: UUID?,
    preferredPaneId: UUID? = nil,
    preferredLeafId: UUID? = nil
  )

  case bot(serverId: String, botId: UUID)

  public var isNewChat: Bool {
    if case .newChat = self { return true }
    return false
  }
}
