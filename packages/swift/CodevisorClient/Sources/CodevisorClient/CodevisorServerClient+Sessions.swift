import ACPKit
import CodevisorProtocol
import Foundation

private struct UpdateWorkspaceBody: Encodable {
  var isArchived: Bool
}

private struct PromptBody: Encodable {
  var text: String
  var clientActionId = UUID().uuidString
  var attachments: [ServerAttachmentRef]?
  var messageId: String?
  var clientId: String?
}

private struct UpdateQueuedPromptBody: Encodable {
  var text: String
}

private struct ReorderQueuedPromptsBody: Encodable {
  var queueItemIds: [String]
}

private struct CancelBody: Encodable {
  var clientActionId = UUID().uuidString
}

private struct SetModeBody: Encodable {
  var modeId: String
  var clientActionId = UUID().uuidString
}

private struct SetConfigBody: Encodable {
  var configId: String
  var value: String
  var clientActionId = UUID().uuidString
}

private struct SetConfigResponse: Decodable {
  var configId: String
  var configOptions: [SessionConfigOption]?
}

struct SetGoalBody: Encodable {
  var objective: String?
  var status: GoalStatus?
  var tokenBudget: TokenBudgetUpdate
  var clientActionId = UUID().uuidString

  private enum Keys: String, CodingKey {
    case objective, status, tokenBudget, clientActionId
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encodeIfPresent(objective, forKey: .objective)
    try container.encodeIfPresent(status, forKey: .status)
    switch tokenBudget {
    case .keep:
      break
    case .clear:
      try container.encodeNil(forKey: .tokenBudget)
    case let .set(budget):
      try container.encode(budget, forKey: .tokenBudget)
    }
    try container.encode(clientActionId, forKey: .clientActionId)
  }
}

private struct AnswerQuestionBody: Encodable {
  var outcome: String
  var answers: [String: QuestionAnswerEntry]?
  var clientActionId = UUID().uuidString
}

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

  public func transcriptPage(id: UUID, before: String?, limit: Int = 32) async throws -> ServerTranscriptPage {
    var components = URLComponents()
    components.path = "/v1/sessions/\(id.uuidString)/transcript"
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    if let before {
      components.queryItems?.append(URLQueryItem(name: "before", value: before))
    }
    guard let path = components.string else { throw CodevisorServerClientError.invalidURL("transcript") }
    return try await get(path)
  }

  public func transcriptItemDetails(
    id: UUID,
    itemId: String,
    after: String?
  ) async throws -> ServerTranscriptItemDetails {
    let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
    let suffix = after.map { "?after=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
    return try await get("/v1/sessions/\(id.uuidString)/transcript/\(encoded)/details\(suffix)")
  }

  public func transcriptBodyPage(
    id: UUID, itemId: String, key: String, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    var components = URLComponents()
    components.path = "/v1/sessions/\(id.uuidString)/transcript/\(itemId)/body"
    components.queryItems = [
      URLQueryItem(name: "key", value: key), URLQueryItem(name: "field", value: field),
      URLQueryItem(name: "position", value: String(position)),
    ]
    guard let path = components.string else { throw CodevisorServerClientError.invalidResponse }
    return try await get(path)
  }

  public func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
    try await get("/v1/sessions/\(id.uuidString)/queue")
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

  public func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text, attachments: [])
  }

  public func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef]
  ) async throws -> ServerPromptAccepted {
    try await promptSession(id: id, text: text, attachments: attachments, messageId: nil)
  }

  public func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
  ) async throws -> ServerPromptAccepted {
    try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId, clientId: nil
    )
  }

  public func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?
  ) async throws -> ServerPromptAccepted {
    try await send(
      "/v1/sessions/\(id.uuidString)/prompt",
      method: "POST",
      body: PromptBody(
        text: text,
        attachments: attachments.isEmpty ? nil : attachments,
        messageId: messageId,
        clientId: clientId
      )
    )
  }

  public func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws {
    do {
      try await sendNoResponse(
        "/v1/workspaces/\(id.uuidString)",
        method: "PATCH",
        body: UpdateWorkspaceBody(isArchived: isArchived)
      )
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return
    } catch CodevisorServerClientError.httpStatus(405, _) {
      return
    }
  }

  public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    let response = try await performRaw(
      Self.uploadPath(name: name),
      method: "POST",
      body: data,
      contentType: mimeType
    )
    return try decoder.decode(ServerFileMetadata.self, from: response)
  }

  public func uploadFile(name: String, mimeType: String, fileURL: URL) async throws -> ServerFileMetadata {
    let response = try await performUpload(
      Self.uploadPath(name: name),
      fileURL: fileURL,
      contentType: mimeType
    )
    return try decoder.decode(ServerFileMetadata.self, from: response)
  }

  private static func uploadPath(name: String) -> String {
    let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
    return "/v1/files?name=\(encodedName)"
  }

  public func filePreview(id: String) async throws -> Data {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await performRaw("/v1/files/\(encoded)?preview=1", method: "GET", body: nil, contentType: nil)
  }

  public func filePreview(path: String, sessionId: UUID?) async throws -> Data {
    var components = URLComponents()
    components.path = "/v1/fs/file"
    components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "preview", value: "1")]
    if let sessionId { components.queryItems?.append(URLQueryItem(name: "sessionId", value: sessionId.uuidString)) }
    guard let requestPath = components.string else { throw CodevisorServerClientError.invalidResponse }
    return try await performRaw(requestPath, method: "GET", body: nil, contentType: nil)
  }

  public func fileData(id: String) async throws -> Data {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await performRaw("/v1/files/\(encoded)", method: "GET", body: nil, contentType: nil)
  }

  public func fileData(sessionId: UUID, path: String) async throws -> Data {
    let requestPath = try liveFileRequestPath(sessionId: sessionId, path: path)
    return try await performRaw(requestPath, method: "GET", body: nil, contentType: nil)
  }

  public func fileVersion(sessionId: UUID, path: String) async throws -> String? {
    let requestPath = try liveFileRequestPath(sessionId: sessionId, path: path)
    let (_, response) = try await performRawResponse(
      requestPath,
      method: "HEAD",
      body: nil,
      contentType: nil
    )
    if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
      return etag
    }
    let fallback = [
      response.value(forHTTPHeaderField: "Last-Modified"),
      response.value(forHTTPHeaderField: "Content-Length"),
    ].compactMap { $0 }.joined(separator: ":")
    return fallback.isEmpty ? nil : fallback
  }

  private func liveFileRequestPath(sessionId: UUID, path: String) throws -> String {
    var components = URLComponents()
    components.path = "/v1/fs/file"
    components.queryItems = [
      URLQueryItem(name: "path", value: path),
      URLQueryItem(name: "sessionId", value: sessionId.uuidString),
    ]
    guard let requestPath = components.string else {
      throw CodevisorServerClientError.invalidURL("fs/file")
    }
    return requestPath
  }

  public func updateQueuedPrompt(
    sessionId: UUID, queueItemId: String, text: String
  ) async throws -> ServerPromptQueueItem {
    try await send(
      "/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)",
      method: "PATCH",
      body: UpdateQueuedPromptBody(text: text)
    )
  }

  public func reorderQueuedPrompts(
    sessionId: UUID,
    queueItemIds: [String]
  ) async throws -> [ServerPromptQueueItem] {
    try await send(
      "/v1/sessions/\(sessionId.uuidString)/queue",
      method: "PATCH",
      body: ReorderQueuedPromptsBody(queueItemIds: queueItemIds)
    )
  }

  public func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {
    try await sendNoResponse("/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)", method: "DELETE")
  }

  public func cancelSession(id: UUID) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/cancel",
      method: "POST",
      body: CancelBody()
    )
  }

  public func setSessionMode(id: UUID, modeId: String) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/mode",
      method: "POST",
      body: SetModeBody(modeId: modeId)
    )
  }

  public func setSessionConfig(id: UUID, configId: String, value: String) async throws {
    _ = try await setSessionConfigAndReturnOptions(id: id, configId: configId, value: value)
  }

  public func setSessionConfigAndReturnOptions(
    id: UUID,
    configId: String,
    value: String
  ) async throws -> [SessionConfigOption]? {
    let response: SetConfigResponse = try await send(
      "/v1/sessions/\(id.uuidString)/config",
      method: "POST",
      body: SetConfigBody(configId: configId, value: value),
      timeout: Self.configRequestTimeout
    )
    return response.configOptions
  }

  static let configRequestTimeout: TimeInterval = 20

  @discardableResult
  public func setSessionGoal(
    id: UUID,
    objective: String?,
    status: GoalStatus?,
    tokenBudget: TokenBudgetUpdate
  ) async throws -> SessionGoal {
    try await send(
      "/v1/sessions/\(id.uuidString)/goal",
      method: "POST",
      body: SetGoalBody(objective: objective, status: status, tokenBudget: tokenBudget)
    )
  }

  public func clearSessionGoal(id: UUID) async throws {
    try await sendNoResponse("/v1/sessions/\(id.uuidString)/goal", method: "DELETE")
  }

  public func cancelSessionAutoResume(id: UUID) async throws {
    try await sendNoResponse("/v1/sessions/\(id.uuidString)/auto-resume", method: "DELETE")
  }

  public func answerSessionQuestion(
    id: UUID,
    questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/questions/\(questionId)/answer",
      method: "POST",
      body: AnswerQuestionBody(outcome: outcome, answers: answers)
    )
  }

  private func createSession(_ session: ChatSession, workspaceId: UUID? = nil) async throws -> ServerSession {
    try await send(
      "/v1/sessions",
      method: "POST",
      body: CreateSessionBody(session: session, workspaceId: workspaceId)
    )
  }
}
