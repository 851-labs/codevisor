import CodevisorCore
import Foundation

struct HomeWorkspaceListItem: Identifiable {
  let workspace: Workspace
  let sessions: [ChatSession]
  let primarySession: ChatSession?
  let project: Project?

  var id: UUID { workspace.id }
}
