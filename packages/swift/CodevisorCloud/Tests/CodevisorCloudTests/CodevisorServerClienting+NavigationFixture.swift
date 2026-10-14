import CodevisorClient

extension CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let projects = try await listProjects()
    let sessions = try await listSessions()
    return ServerNavigationSnapshot(
      eventCursor: 0, projects: projects, sessions: sessions,
      workspaces: [], panes: [])
  }
}
