import SwiftUI
import CodevisorCore

extension ClassicSidebarView {
  func selectNextChat(serverId: String) {
    let next = environment.projectList.sessions
      .filter { $0.serverId == serverId }
      .max { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) }
    if let next { store?.selectChat(next) }
    selection = next.map { .session(serverId: $0.serverId, id: $0.id) }
  }

  func activateSession(_ session: ChatSession) {
    if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
      let workspace = environment.workspaces.workspace(id: workspaceId),
      workspace.isArchived
    {
      environment.unarchiveWorkspace(workspace)
    }
    let target = SidebarSelection.session(serverId: session.serverId, id: session.id)
    store?.selectChat(session)
    selection = target
  }

}
