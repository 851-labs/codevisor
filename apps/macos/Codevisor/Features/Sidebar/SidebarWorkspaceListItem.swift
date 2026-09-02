import CodevisorCore
import Foundation

/// A workspace row in either workspace-based mode. Its tabs and primary
/// session/project are resolved from the live session list so status and
/// activation reuse the session machinery.
struct SidebarWorkspaceListItem: Identifiable {
  let workspace: Workspace
  let sessions: [ChatSession]
  let primarySession: ChatSession?
  let project: Project?

  var id: SidebarFleetItemID { .workspace(workspace) }
}
