import Foundation

/// Fleet-wide views of the projection: every machine's projects and chats,
/// selected or not -- the flattened sidebar's data.
extension ProjectListModel {
  /// Fetches a machine's latest projects and chats now (for pickers that
  /// must list a project created a moment ago elsewhere).
  @discardableResult
  public func refreshFromServer(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    guard let navigationStore else { return .failed("No navigation store") }
    return await navigationStore.refresh(machineId: serverId, client: client)
  }

  /// The server's workspace assignment for every chat on a machine, with
  /// waiting changes applied. Empty is valid for unassigned chats.
  /// The workspace a chat belongs to, in O(1).
  public func workspaceId(forSession sessionId: UUID) -> UUID? {
    navigationStore?.projection.sessionIndex[sessionId]
  }

  public func workspaceAssignments(for serverId: String) -> [UUID: UUID] {
    guard let projection = navigationStore?.projection else { return [:] }
    var assignments: [UUID: UUID] = [:]
    for session in sessions where session.serverId == serverId {
      if let workspaceId = projection.sessionIndex[session.id] { assignments[session.id] = workspaceId }
    }
    return assignments
  }

  /// Sessions visible in a project on the project's OWN machine (not the
  /// selected one) — the flattened sidebar's per-project scope.
  public func fleetSessions(in project: Project) -> [ChatSession] {
    sessions
      .filter { session in
        session.projectId == project.id
          && session.serverId == project.serverId
          && (session.origin == .codevisor || showsImportedSessions)
      }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  /// Active projects across EVERY machine — the flattened sidebar's root.
  public var fleetActiveProjects: [Project] {
    projects
      .filter { $0.origin == .codevisor || !fleetSessions(in: $0).isEmpty }
      .sorted { $0.createdAt > $1.createdAt }
  }

  /// Every machine's active projects, ordered by each project's most
  /// recent workspace; projects without workspace history keep their
  /// newest-project-first order after used ones. The composer's project
  /// picker lists these — picking a project IS picking its machine.
  public func fleetActiveProjectsByWorkspaceRecency(
    _ workspaces: [Workspace]
  ) -> [Project] {
    var latestWorkspaceDates: [String: Date] = [:]
    for workspace in workspaces {
      let key = "\(workspace.serverId)|\(workspace.projectId.uuidString)"
      latestWorkspaceDates[key] = max(
        latestWorkspaceDates[key] ?? .distantPast,
        workspace.createdAt
      )
    }
    return fleetActiveProjects.enumerated().sorted { left, right in
      let leftKey = "\(left.element.serverId)|\(left.element.id.uuidString)"
      let rightKey = "\(right.element.serverId)|\(right.element.id.uuidString)"
      switch (latestWorkspaceDates[leftKey], latestWorkspaceDates[rightKey]) {
      case let (leftDate?, rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return left.offset < right.offset
      }
    }
    .map(\.element)
  }
}
