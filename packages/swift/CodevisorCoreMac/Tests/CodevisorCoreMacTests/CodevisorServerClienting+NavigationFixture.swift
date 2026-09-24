import CodevisorClient

// Compose fixture state only; production clients use the atomic endpoint.
// No fake in this target stores workspaces or panes.
extension CodevisorServerClienting {
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let projects = try await listProjects()
    let sessions = try await listSessions()
    return ServerNavigationSnapshot(
      eventCursor: 0, projects: projects, sessions: sessions,
      workspaces: [], panes: [])
  }
}
