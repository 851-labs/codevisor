import CodevisorProtocol
import Foundation

struct CreateSessionBody: Encodable {
  var sidebarOrderHead = WorkspaceOrderClock.shared.head
  var sidebarPosition: String?
  var id: String
  var projectId: String
  var harnessId: String
  var harnessAccountId: String?
  var agentSessionId: String?
  var title: String
  var origin: SessionOrigin
  var worktreeName: String?
  var workspaceId: String?
  var createdAt: String
  var updatedAt: String?
  var deferAgentSession: Bool?

  init(session: ChatSession, workspaceId: UUID? = nil) {
    id = session.id.uuidString
    projectId = session.projectId.uuidString
    harnessId = session.harnessId
    harnessAccountId = session.harnessAccountId
    agentSessionId = session.agentSessionId
    title = session.title
    origin = session.origin
    worktreeName = session.worktreeName
    self.workspaceId = workspaceId?.uuidString
    sidebarPosition = workspaceId.flatMap(WorkspaceOrderClock.shared.draftPosition(of:))
    createdAt = ServerDateCoding.string(from: session.createdAt)
    updatedAt = session.updatedAt.map(ServerDateCoding.string)
    deferAgentSession = session.hasAgentSession ? nil : true
  }
}

struct UpdateSessionBody: Encodable {
  var sidebarOrderHead = WorkspaceOrderClock.shared.head
  var sidebarPosition: String?
  var agentSessionId: String?
  var title: String
  var titleIntent = "fallback"
  var worktreeName: String?
  var workspaceId: String?
  var harnessId: String?
  var harnessAccountId: String?

  init(session: ChatSession, workspaceId: UUID? = nil) {
    agentSessionId = session.agentSessionId
    title = session.title
    worktreeName = session.worktreeName
    self.workspaceId = workspaceId?.uuidString
    sidebarPosition = workspaceId.flatMap(WorkspaceOrderClock.shared.draftPosition(of:))
    harnessId = session.harnessId.isEmpty ? nil : session.harnessId
    harnessAccountId = session.harnessAccountId
  }
}

struct RenameSessionBody: Encodable {
  var title: String
  var titleIntent = "rename"
}

private struct MarkSessionReadBody: Encodable {
  var throughSequence: Int
}

private struct OpenSessionBody: Encodable {
  var project: CreateProjectBody?
  var session: CreateSessionBody
  var update: UpdateSessionBody
  var transcriptLimit: Int

  init(session: ChatSession, project: Project?, workspaceId: UUID?, transcriptLimit: Int) {
    self.project = project.map(CreateProjectBody.init(project:))
    self.session = CreateSessionBody(session: session, workspaceId: workspaceId)
    self.update = UpdateSessionBody(session: session, workspaceId: workspaceId)
    self.transcriptLimit = transcriptLimit
  }
}

extension CodevisorServerClient {
  public func listSessions() async throws -> [ServerSession] {
    try await get("/v1/sessions")
  }

  public func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits {
    try await get("/v1/sessions/\(id.uuidString)/usage-limits")
  }

  public func sessionContext(id: UUID) async throws -> ServerSessionContext? {
    try await get("/v1/sessions/\(id.uuidString)/context")
  }

  public func openSession(
    _ session: ChatSession,
    project: Project?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse? {
    try await openSession(
      session,
      project: project,
      workspaceId: nil,
      transcriptLimit: transcriptLimit
    )
  }

  public func openSession(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse? {
    try await openSessionReturningData(
      session,
      project: project,
      workspaceId: workspaceId,
      transcriptLimit: transcriptLimit
    )?.response
  }

  public func openSessionReturningData(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResult? {
    let data = try await perform(
      "/v1/sessions/\(session.id.uuidString)/open",
      method: "POST",
      body: OpenSessionBody(
        session: session,
        project: project,
        workspaceId: workspaceId,
        transcriptLimit: transcriptLimit
      )
    )
    return ServerSessionOpenResult(response: try decoder.decode(ServerSessionOpenResponse.self, from: data), data: data)
  }

  public func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    try await upsertSession(session, workspaceId: nil)
  }

  public func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
    let remoteSessions = try await listSessions()
    if remoteSessions.contains(where: { UUID(uuidString: $0.id) == session.id }) {
      return try await updateSession(session, workspaceId: workspaceId)
    }
    return try await createSession(session, workspaceId: workspaceId)
  }

  public func updateSession(_ session: ChatSession) async throws -> ServerSession {
    try await updateSession(session, workspaceId: nil)
  }

  public func renameSession(_ session: ChatSession) async throws -> ServerSession {
    let remoteSessions = try await listSessions()
    if !remoteSessions.contains(where: { UUID(uuidString: $0.id) == session.id }) {
      _ = try await createSession(session, workspaceId: nil)
    }
    return try await send(
      "/v1/sessions/\(session.id.uuidString)",
      method: "PATCH",
      body: RenameSessionBody(title: session.title)
    )
  }

  private func updateSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
    try await send(
      "/v1/sessions/\(session.id.uuidString)",
      method: "PATCH",
      body: UpdateSessionBody(session: session, workspaceId: workspaceId)
    )
  }

  public func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? {
    do {
      return try await send(
        "/v1/sessions/\(id.uuidString)/read",
        method: "POST",
        body: MarkSessionReadBody(throughSequence: throughSequence)
      )
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return nil
    }
  }

  public func markSessionUnread(id: UUID) async throws -> ServerSession? {
    do {
      return try await send(
        "/v1/sessions/\(id.uuidString)/unread",
        method: "POST",
        body: Optional<EmptyBody>.none
      )
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return nil
    }
  }

  public func clearSessionPlanApproval(id: UUID) async throws {
    do {
      try await sendNoResponse(
        "/v1/sessions/\(id.uuidString)/plan-approval",
        method: "DELETE"
      )
    } catch CodevisorServerClientError.httpStatus(404, _) {
    }
  }

  public func deleteSession(id: UUID) async throws {
    try await sendNoResponse("/v1/sessions/\(id.uuidString)", method: "DELETE")
  }

  private func createSession(_ session: ChatSession, workspaceId: UUID? = nil) async throws -> ServerSession {
    try await send(
      "/v1/sessions",
      method: "POST",
      body: CreateSessionBody(session: session, workspaceId: workspaceId)
    )
  }
}
