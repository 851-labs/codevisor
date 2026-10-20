import SwiftUI
import CodevisorCore

extension SidebarView {
  func selectNextChat(serverId: String) {
    let next = environment.projectList.sessions
      .filter { session in
        guard session.serverId == serverId else { return false }
        guard let workspaceId = environment.workspaces.workspaceId(forSession: session.id) else { return true }
        return !folds.isArchiving(workspaceId) && environment.workspaces.workspace(id: workspaceId)?.isArchived != true
      }
      .max { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) }
    if let next { store?.selectChat(next) }
    selection = next.map { .session(serverId: $0.serverId, id: $0.id) }
  }
}
