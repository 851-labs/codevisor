import CodevisorClient

extension CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let cursor = try await latestShellEventCursor()
    async let projectRows = listProjects()
    async let sessionRows = listSessions()
    let (projects, sessions) = try await (projectRows, sessionRows)
    return ServerNavigationSnapshot(
      eventCursor: cursor, projects: projects, sessions: sessions,
      workspaces: [], panes: [])
  }
}
