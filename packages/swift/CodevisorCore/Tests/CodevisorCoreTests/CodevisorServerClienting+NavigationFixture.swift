import CodevisorClient

// Compose fixture state only; production clients use the atomic endpoint.
// Fakes that store workspaces or panes implement `navigationSnapshot` themselves.
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
