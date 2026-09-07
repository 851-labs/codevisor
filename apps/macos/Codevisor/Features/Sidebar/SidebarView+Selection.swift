import SwiftUI
import CodevisorCore

extension SidebarView {
  /// Selects the most recent active chat after archiving a workspace.
  /// An empty machine falls through to the new-workspace screen.
  func selectNextChat(serverId: String) {
    let next = environment.projectList.sessions
      .filter { $0.serverId == serverId && !$0.isArchived }
      .max { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) }
    selection = next.map { .session(serverId: $0.serverId, id: $0.id) }
  }

  func activateSession(_ session: ChatSession) {
    // Restoring/opening a chat whose workspace was archived revives the
    // workspace — layout intact. Routed through the environment so the
    // revival reaches the server too; a bare local save left other
    // devices (and the server's cascade) believing it was still archived.
    if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
      let workspace = environment.workspaces.workspace(id: workspaceId),
      workspace.isArchived
    {
      environment.unarchiveWorkspace(workspace)
      workspaceRevision += 1
    }
    let target = SidebarSelection.session(serverId: session.serverId, id: session.id)
    guard selection != target else { return }
    // A route owns its machine identity. Opening a chat on another machine
    // is the same synchronous selection change as opening a sibling chat;
    // its controller resolves that machine's client independently.
    selection = target
  }

}
