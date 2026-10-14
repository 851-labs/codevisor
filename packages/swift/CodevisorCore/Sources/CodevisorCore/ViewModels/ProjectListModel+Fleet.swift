import Foundation

extension ProjectListModel {
  @discardableResult
  public func refreshFromServer(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    guard let navigationStore else { return .failed("No navigation store") }
    return await navigationStore.refresh(machineId: serverId, client: client)
  }

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

  public func fleetSessions(in project: Project) -> [ChatSession] {
    sessions
      .filter { session in
        session.projectId == project.id
          && session.serverId == project.serverId
          && (session.origin == .codevisor || showsImportedSessions)
      }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  public var fleetActiveProjects: [Project] {
    projects
      .filter { $0.origin == .codevisor || !fleetSessions(in: $0).isEmpty }
      .sorted { $0.createdAt > $1.createdAt }
  }

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
