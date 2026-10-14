import CodevisorCore
import Foundation

struct WorkspaceWindowRoute: Codable, Hashable {
  var serverId: String
  var workspaceId: UUID
  var anchorSessionId: UUID?
  var chatSessionId: UUID?
  var paneId: UUID?

  var homeRoute: HomeRoute {
    .workspace(
      serverId: serverId,
      workspaceId: workspaceId,
      anchorSessionId: anchorSessionId,
      preferredChatSessionId: chatSessionId,
      preferredPaneId: paneId
    )
  }
}
