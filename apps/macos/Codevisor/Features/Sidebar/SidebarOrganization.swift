enum SidebarOrganization: String, CaseIterable {
  case compact
  case byWorkspace
  case byProject

  var title: String {
    switch self {
    case .compact: return "Agents"
    case .byWorkspace: return "Workspaces"
    case .byProject: return "Projects"
    }
  }
}
