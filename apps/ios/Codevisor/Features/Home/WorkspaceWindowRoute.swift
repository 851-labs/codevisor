import CodevisorCore
import Foundation

/// What a window opened on one workspace tab shows. Codable so the system
/// can restore the window; opening an already-open route brings that window
/// forward instead of duplicating it.
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
