import Foundation

public enum NavigationIntent: Codable, Equatable, Sendable {
  case upsertProject(Project)
  case deleteProject(projectId: UUID, sessionIds: [UUID], deletesFiles: Bool? = nil)
  case setProjectWorktreeBase(projectId: UUID, worktreeBase: ProjectWorktreeBase?)
  case setProjectDefaultRunLocation(projectId: UUID, location: ProjectRunLocation?)
  case upsertSession(ChatSession, workspaceId: UUID?)
  case expectSession(ChatSession)
  case renameSession(ChatSession)
  case deleteSession(sessionId: UUID)
  case markSessionRead(sessionId: UUID, throughSequence: Int)
  case markSessionUnread(sessionId: UUID)
  case renameWorkspace(workspaceId: UUID, name: String, hasCustomName: Bool)
  case setWorkspaceArchived(workspaceId: UUID, isArchived: Bool)
  case reorderWorkspace(workspaceId: UUID, position: String, expectedRevision: Int)
  case movePane(paneId: UUID, workspaceId: UUID, position: String)
  case upsertPane(PaneDescriptorState, workspaceId: UUID)
  case closePane(paneId: UUID, workspaceId: UUID)
  case promotePane(PaneDescriptorState, workspaceId: UUID, session: ChatSession)

  public var coalescingKey: String {
    switch self {
    case let .upsertProject(project): "project:\(project.id)"
    case let .deleteProject(projectId, _, _): "project:\(projectId)"
    case let .setProjectWorktreeBase(projectId, _): "project-base:\(projectId)"
    case let .setProjectDefaultRunLocation(projectId, _): "project-run-location:\(projectId)"
    case let .upsertSession(session, _): "session:\(session.id)"
    case let .expectSession(session): "session:\(session.id)"
    case let .renameSession(session): "session-title:\(session.id)"
    case let .deleteSession(sessionId): "session:\(sessionId)"
    case let .markSessionRead(sessionId, _), let .markSessionUnread(sessionId): "read:\(sessionId)"
    case let .renameWorkspace(workspaceId, _, _): "ws:\(workspaceId):name"
    case let .setWorkspaceArchived(workspaceId, _): "ws:\(workspaceId):archive"
    case let .reorderWorkspace(workspaceId, _, _): "ws:\(workspaceId):order"
    case let .movePane(paneId, _, _): "pane-order:\(paneId)"
    case let .upsertPane(pane, _): "pane:\(pane.id)"
    case let .closePane(paneId, _): "pane:\(paneId)"
    case let .promotePane(pane, _, _): "pane:\(pane.id)"
    }
  }

  public var workspaceId: UUID? {
    switch self {
    case let .upsertSession(_, workspaceId): workspaceId
    case let .upsertPane(_, workspaceId), let .closePane(_, workspaceId),
      let .promotePane(_, workspaceId, _), let .movePane(_, workspaceId, _):
      workspaceId
    case .upsertProject, .deleteProject, .setProjectWorktreeBase, .setProjectDefaultRunLocation,
      .expectSession, .renameSession, .deleteSession, .markSessionRead, .markSessionUnread,
      .renameWorkspace, .setWorkspaceArchived, .reorderWorkspace:
      nil
    }
  }

  var isSentElsewhere: Bool {
    if case .expectSession = self { return true }
    return false
  }

  var expectedSessionId: UUID? {
    if case let .expectSession(session) = self { return session.id }
    return nil
  }

  var upsertedProjectId: UUID? {
    if case let .upsertProject(project) = self { return project.id }
    return nil
  }

  var isRemoval: Bool {
    switch self {
    case .deleteProject, .deleteSession, .closePane: true
    default: false
    }
  }

  func perform(with client: any CodevisorServerClienting) async throws {
    switch self {
    case let .upsertProject(project):
      _ = try await client.upsertProject(project)
    case let .deleteProject(projectId, sessionIds, deletesFiles):
      for sessionId in sessionIds {
        try await Self.ignoringMissing { try await client.deleteSession(id: sessionId) }
      }
      if deletesFiles == true {
        try await client.deleteProject(id: projectId, deletingFiles: true)
      } else {
        try await client.deleteProject(id: projectId)
      }
    case let .setProjectWorktreeBase(projectId, worktreeBase):
      _ = try await client.updateProjectWorktreeBase(id: projectId, worktreeBase: worktreeBase)
    case let .setProjectDefaultRunLocation(projectId, location):
      _ = try await client.updateProjectDefaultRunLocation(id: projectId, defaultRunLocation: location)
    case let .upsertSession(session, workspaceId):
      if let workspaceId {
        _ = try await client.upsertSession(session, workspaceId: workspaceId)
      } else {
        _ = try await client.upsertSession(session)
      }
    case .expectSession:
      return
    case let .renameSession(session):
      _ = try await client.renameSession(session)
    case let .deleteSession(sessionId):
      try await client.deleteSession(id: sessionId)
    case let .markSessionRead(sessionId, throughSequence):
      _ = try await client.markSessionRead(id: sessionId, throughSequence: throughSequence)
    case let .markSessionUnread(sessionId):
      _ = try await client.markSessionUnread(id: sessionId)
    case let .renameWorkspace(workspaceId, name, hasCustomName):
      try await client.renameWorkspace(id: workspaceId, name: name, hasCustomName: hasCustomName)
    case let .setWorkspaceArchived(workspaceId, isArchived):
      try await client.setWorkspaceArchived(id: workspaceId, isArchived: isArchived)
    case let .reorderWorkspace(workspaceId, position, expectedRevision):
      _ = try await client.reorderWorkspace(
        id: workspaceId, position: position, expectedRevision: expectedRevision)
    case let .movePane(paneId, workspaceId, position):
      try await Self.ignoringMissing {
        try await client.moveWorkspacePane(workspaceId: workspaceId, paneId: paneId, position: position)
      }
    case let .upsertPane(pane, workspaceId):
      _ = try await client.upsertWorkspacePane(
        ServerPaneMapping.record(from: pane, workspaceId: workspaceId, createdAt: Date()))
    case let .closePane(paneId, workspaceId):
      _ = try await client.closeWorkspacePane(workspaceId: workspaceId, paneId: paneId)
    case let .promotePane(pane, workspaceId, session):
      let record = ServerPaneMapping.record(from: pane, workspaceId: workspaceId, createdAt: Date())
      let promoted: Bool
      do {
        promoted = try await client.promoteWorkspacePaneToChat(record, session: session) != nil
      } catch CodevisorServerClientError.httpStatus(404, _) {
        promoted = false
      }
      if !promoted {
        _ = try await client.upsertSession(session)
        _ = try await client.upsertWorkspacePane(record)
        _ = try await client.upsertSession(session, workspaceId: workspaceId)
      }
    }
  }

  private static func ignoringMissing(_ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return
    }
  }
}
