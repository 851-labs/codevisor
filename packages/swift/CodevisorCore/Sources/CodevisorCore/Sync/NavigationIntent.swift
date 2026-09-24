import Foundation

/// One change the user made to server-owned navigation state, waiting in the
/// outbox until the server has it.
///
/// The device never edits its copy of server state. It records what the user
/// asked for here, shows it on top of the cached server state until the
/// server's own copy catches up (see `NavigationOverlay`), and sends it to the
/// machine that owns the record (see `NavigationOutboxExecutor`). Every case
/// maps to a request the server treats as idempotent, so resending one after
/// an ambiguous failure is always safe.
public enum NavigationIntent: Codable, Equatable, Sendable {
  case upsertProject(Project)
  /// Deleting a project deletes its chats with it; the ids are the chats the
  /// user saw at the time, so they disappear together.
  case deleteProject(projectId: UUID, sessionIds: [UUID])
  case upsertSession(ChatSession, workspaceId: UUID?)
  /// A chat that opening it will create on the server (the new-chat composer
  /// makes the chat before its first message). It is shown right away but
  /// never sent: the open request carries it, and the entry leaves once the
  /// server lists the chat.
  case expectSession(ChatSession)
  case renameSession(ChatSession)
  case deleteSession(sessionId: UUID)
  case markSessionRead(sessionId: UUID, throughSequence: Int)
  case markSessionUnread(sessionId: UUID)
  case renameWorkspace(workspaceId: UUID, name: String, hasCustomName: Bool)
  case setWorkspaceArchived(workspaceId: UUID, isArchived: Bool)
  /// `expectedRevision` is the order revision this device last saw. The
  /// server applies the move only if nobody reordered since; otherwise it
  /// keeps its order and this device simply shows that.
  case reorderWorkspace(workspaceId: UUID, position: String, expectedRevision: Int)
  case upsertPane(PaneDescriptorState, workspaceId: UUID)
  case closePane(paneId: UUID, workspaceId: UUID)
  /// Turns a pane the server already lists into a chat, keeping its id.
  case promotePane(PaneDescriptorState, workspaceId: UUID, session: ChatSession)

  /// A newer request with the same key replaces an older one that has not
  /// been sent yet: only the latest name, order, or pane state matters.
  public var coalescingKey: String {
    switch self {
    case let .upsertProject(project): "project:\(project.id)"
    case let .deleteProject(projectId, _): "project:\(projectId)"
    case let .upsertSession(session, _): "session:\(session.id)"
    case let .expectSession(session): "session:\(session.id)"
    case let .renameSession(session): "session-title:\(session.id)"
    case let .deleteSession(sessionId): "session:\(sessionId)"
    case let .markSessionRead(sessionId, _), let .markSessionUnread(sessionId): "read:\(sessionId)"
    case let .renameWorkspace(workspaceId, _, _): "ws:\(workspaceId):name"
    case let .setWorkspaceArchived(workspaceId, _): "ws:\(workspaceId):archive"
    case let .reorderWorkspace(workspaceId, _, _): "ws:\(workspaceId):order"
    case let .upsertPane(pane, _): "pane:\(pane.id)"
    case let .closePane(paneId, _): "pane:\(paneId)"
    case let .promotePane(pane, _, _): "pane:\(pane.id)"
    }
  }

  /// The workspace this request needs to exist on the server first. Requests
  /// for a workspace that is still a draft on this device wait until opening
  /// its first chat creates it.
  public var workspaceId: UUID? {
    switch self {
    case let .upsertSession(_, workspaceId): workspaceId
    case let .upsertPane(_, workspaceId), let .closePane(_, workspaceId),
      let .promotePane(_, workspaceId, _):
      workspaceId
    case .upsertProject, .deleteProject, .expectSession, .renameSession, .deleteSession, .markSessionRead,
      .markSessionUnread, .renameWorkspace, .setWorkspaceArchived, .reorderWorkspace:
      nil
    }
  }

  /// Sent by something other than the outbox (see `expectSession`).
  var isSentElsewhere: Bool {
    if case .expectSession = self { return true }
    return false
  }

  /// The chat an `expectSession` entry is waiting for the server to list.
  var expectedSessionId: UUID? {
    if case let .expectSession(session) = self { return session.id }
    return nil
  }

  /// A delete that finds nothing to delete has already happened.
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
    case let .deleteProject(projectId, sessionIds):
      for sessionId in sessionIds {
        try await Self.ignoringMissing { try await client.deleteSession(id: sessionId) }
      }
      try await client.deleteProject(id: projectId)
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
    case let .upsertPane(pane, workspaceId):
      _ = try await client.upsertWorkspacePane(
        WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspaceId, createdAt: Date()))
    case let .closePane(paneId, workspaceId):
      _ = try await client.closeWorkspacePane(workspaceId: workspaceId, paneId: paneId)
    case let .promotePane(pane, workspaceId, session):
      let record = WorkspaceSyncModel.serverPane(from: pane, workspaceId: workspaceId, createdAt: Date())
      // Only a pane the server already lists can be converted in place. A
      // New Tab page never left this device, and an older server can't
      // promote: both create the chat, list its pane, then assign it -- the
      // order that never shows the chat twice.
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
