import CodevisorClient

// Compose fixture state only; production clients use the atomic endpoint.
extension CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let cursor = try await latestShellEventCursor()
    async let projectRows = listProjects()
    async let sessionRows = listSessions()
    async let workspaceRows = workspaceSnapshot()
    let (projects, sessions, state) = try await (projectRows, sessionRows, workspaceRows)
    let workspaces = state?.workspaces ?? []
    let panes = state?.panes ?? []
    return ServerNavigationSnapshot(
      eventCursor: cursor, projects: projects, sessions: sessions,
      workspaces: workspaces, panes: panes)
  }
}
