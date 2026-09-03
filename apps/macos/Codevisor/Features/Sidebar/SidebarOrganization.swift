enum SidebarOrganization: String, CaseIterable {
  case compact
  case byWorkspace
  case byProject
  /// Prototype: workspaces whose TABS are the sidebar rows. The in-content
  /// tab strip stays hidden; ⌘T adds a row here instead.
  case nous

  var title: String {
    switch self {
    case .compact: return "Agents"
    case .byWorkspace: return "Workspaces"
    case .byProject: return "Projects"
    case .nous: return "Nous"
    }
  }

  /// Whether workspaces (rather than chats or projects) are the top-level rows.
  var isWorkspaceList: Bool { self == .byWorkspace || self == .nous }
}
