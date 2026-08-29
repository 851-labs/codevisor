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
        Self(kind: .project, serverId: project.serverId, entityId: project.id)
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
    var sidebarFleetOrderID: String { "project|\(serverId)|\(id.uuidString)" }
}

extension ChatSession {
    var sidebarFleetItemID: SidebarFleetItemID { .session(self) }
    var sidebarFleetOrderID: String { "session|\(serverId)|\(id.uuidString)" }
}

struct SidebarSessionListItem: Identifiable {
    let session: ChatSession
    let project: Project

    var id: SidebarFleetItemID { session.sidebarFleetItemID }
    var orderingID: String { session.sidebarFleetOrderID }
}
