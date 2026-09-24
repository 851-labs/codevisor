import CodevisorCore

/// A workspace and the chat that can route into its tabs. The routing chat
/// may be archived when the workspace contains only non-chat content.
struct SidebarWorkspaceListItem {
  let workspace: Workspace
  let routingSession: ChatSession?
}
