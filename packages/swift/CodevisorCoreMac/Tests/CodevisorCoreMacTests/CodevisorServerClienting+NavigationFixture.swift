import CodevisorClient

// Compose fixture state only; production clients use the atomic endpoint.
extension CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let projects = try await listProjects()
    let sessions = try await listSessions()
    let workspaces = try await listWorkspaces() ?? []
    let panes = try await listWorkspacePanes() ?? []
    return ServerNavigationSnapshot(
      eventCursor: 0, projects: projects, sessions: sessions,
      workspaces: workspaces, panes: panes)
  }
}
