import CodevisorCore
import Foundation

/// SwiftUI identity for a fleet row. Server UUIDs are only unique within one
/// machine, and project/session/workspace UUIDs occupy separate namespaces.
struct SidebarFleetItemID: Hashable {
  enum Kind: Hashable {
    case project
    case session
    case workspace
  }

  let kind: Kind
  let serverId: String
  let entityId: UUID

  static func project(_ project: Project) -> Self {
    .project(serverId: project.serverId, id: project.id)
  }

  static func project(serverId: String, id: UUID) -> Self {
    Self(kind: .project, serverId: serverId, entityId: id)
  }

  static func session(_ session: ChatSession) -> Self {
    Self(kind: .session, serverId: session.serverId, entityId: session.id)
  }

  static func session(serverId: String, id: UUID) -> Self {
    Self(kind: .session, serverId: serverId, entityId: id)
  }

  static func workspace(_ workspace: Workspace) -> Self {
    Self(kind: .workspace, serverId: workspace.serverId, entityId: workspace.id)
  }
}

extension Project {
  var sidebarFleetItemID: SidebarFleetItemID { .project(self) }
}

extension ChatSession {
  var sidebarFleetItemID: SidebarFleetItemID { .session(self) }
}

struct SidebarSessionListItem: Identifiable {
  let session: ChatSession
  let project: Project

  var id: SidebarFleetItemID { session.sidebarFleetItemID }
}
