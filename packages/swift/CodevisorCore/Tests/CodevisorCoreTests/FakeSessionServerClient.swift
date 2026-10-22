import CodevisorTestSupport
import Observation
import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

@Observable
final class FakeSessionServerClient: CodevisorServerClienting, @unchecked Sendable {
  let sessionId: UUID
  private let projectId = UUID()
  private var _eventBuffer: [ServerEventEnvelope] = []
  private var _eventContinuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
  private let lock = NSLock()
  let promptDelivery = FakePromptDelivery()

  private var _runtimeRequests: [String] = []

  var runtimeRequests: [String] { lock.withLock { _runtimeRequests } }

  private var _promptedTexts: [String] = []
  private var _promptedAttachments: [[ServerAttachmentRef]] = []
  private var _promptedMessageIds: [String?] = []
  private var _promptedClientIds: [String?] = []
  private var _promptGate: AsyncStream<Void>?
  private var _cancelCount = 0
  private var _eventSinceValues: [Int] = []
  private var _sessionEventSinceValues: [Int] = []
  private var _transcriptPageRequests: [(before: String?, limit: Int)] = []
  private var _transcriptDetailRequestCount = 0
  private var _transcriptDetailGate: AsyncStream<Void>?
  private var _promptQueueResponse: [ServerPromptQueueItem] = []
  private var _promptQueueGate: AsyncStream<Void>?
  private var _promptQueueRequestCount = 0
  private var _failNextPromptQueue = false
  private var _queueUpdates: [(id: String, text: String, attachments: [ServerAttachmentRef]?)] = []
  private var _queueReorders: [[String]] = []
  private var _queueDeletes: [String] = []
  private var _queueMutationFailuresRemaining = 0
  private var _goalUpdates: [(String?, GoalStatus?, TokenBudgetUpdate)] = []
  private var _goalClearCount = 0
  private var _nextGoalClearShouldFail = false
  private var _autoResumeCancelCount = 0
  private var _nextAutoResumeCancelShouldFail = false
  private var _lastBudget: Int?
  private var _questionAnswers: [(String, String, [String: QuestionAnswerEntry]?)] = []
  private var _questionAnswerGate: AsyncStream<Void>?
  private var _nextEnvelopeId = 1

  var detailCursor = 0
  var initialTranscriptPage: ServerTranscriptPage?
  var botConversationPage = ServerBotConversationPage(messages: [], hasMore: false, working: false)
  var olderTranscriptPage: ServerTranscriptPage?
  var olderTranscriptPageHandler: (@Sendable (String) async throws -> ServerTranscriptPage)?
  let olderTranscriptPageRequests = TestSignal()
  let transcriptPageFaults = FakeTranscriptPageFaults()
  let transcriptDetailRequests = TestSignal()
  var transcriptDetailsByItem: [String: ServerTranscriptItemDetails] = [:]
  var transcriptDetailHandler: (@Sendable (String, String?) async throws -> ServerTranscriptItemDetails)?
  let configUpdateReplies = FakeConfigUpdates()
  var transcriptBodyHandler: (@Sendable (String, String, String, Int) async throws -> ServerTranscriptBodyPage)?
  private var _transcriptBodyRequests: [Int] = []
  var transcriptBodyRequests: [Int] { lock.withLock { _transcriptBodyRequests } }
  private var _transcriptDetailCursors: [String?] = []
  var transcriptDetailCursors: [String?] { lock.withLock { _transcriptDetailCursors } }
  var echoOnPrompt = true
  var openSessionResponse: ServerSessionOpenResponse?
  var openSessionFailure: CodevisorServerClientError?
  var openSessionGate: AsyncStream<Void>?
  let openSessionRequests = TestSignal()
  var promptFailure: CodevisorServerClientError?
  let sendAttempts = FakeSendAttempts()
  let setupRequests = FakeSetupRequests()
  let promptRequests = TestSignal()

  func openSession(
    _ session: ChatSession, project: Project?, transcriptLimit: Int
  ) async throws -> ServerSessionOpenResponse? {
    openSessionRequests.signal()
    if let openSessionGate { for await _ in openSessionGate {} }
    if let openSessionFailure { throw openSessionFailure }
    return openSessionResponse
  }

  init(sessionId: UUID) {
    self.sessionId = sessionId
  }

  private func yieldEvent(_ event: ServerEventEnvelope) {
    let continuations = lock.withLock {
      _eventBuffer.append(event)
      return _eventContinuations
    }
    for continuation in continuations {
      continuation.yield(event)
    }
  }

  let eventReads = TestSignal()

  private func subscribeEvents(
    since: Int
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ServerEventEnvelope.self)
    lock.withLock {
      let liveOnly = since >= ServerSessionTransport.liveOnlyEventCursor
      for event in _eventBuffer where !liveOnly && event.id > since {
        continuation.yield(event)
      }
      _eventContinuations.append(continuation)
    }
    return TrackedStream(stream, reads: eventReads).stream
  }

  var promptedTexts: [String] {
    lock.withLock { _promptedTexts }
  }

  var promptedAttachments: [[ServerAttachmentRef]] {
    lock.withLock { _promptedAttachments }
  }

  var promptedMessageIds: [String?] {
    lock.withLock { _promptedMessageIds }
  }

  var promptedClientIds: [String?] {
    lock.withLock { _promptedClientIds }
  }

  func holdPrompts(until gate: AsyncStream<Void>) {
    lock.withLock { _promptGate = gate }
  }

  var cancelCount: Int {
    lock.withLock { _cancelCount }
  }

  var configUpdates: [(String, String)] {
    configUpdateReplies.recorded
  }

  func holdConfigUpdates(until gate: AsyncStream<Void>) {
    configUpdateReplies.hold(until: gate)
  }

  func failNextConfigUpdate() {
    configUpdateReplies.failNext()
  }

  var eventSinceValues: [Int] {
    lock.withLock { _eventSinceValues }
  }

  var sessionEventSinceValues: [Int] {
    lock.withLock { _sessionEventSinceValues }
  }

  var transcriptPageRequests: [(before: String?, limit: Int)] {
    lock.withLock { _transcriptPageRequests }
  }

  var transcriptDetailRequestCount: Int {
    lock.withLock { _transcriptDetailRequestCount }
  }

  func holdTranscriptDetails(until gate: AsyncStream<Void>) {
    lock.withLock { _transcriptDetailGate = gate }
  }

  func failNextTranscriptPages(_ count: Int, with error: any Error = URLError(.networkConnectionLost)) {
    transcriptPageFaults.failNext(count, with: error)
  }

  func clearTranscriptPageFailures() {
    transcriptPageFaults.clear()
  }

  var promptQueueRequestCount: Int {
    lock.withLock { _promptQueueRequestCount }
  }

  func setPromptQueueResponse(_ queue: [ServerPromptQueueItem]) {
    lock.withLock { _promptQueueResponse = queue }
  }

  func holdPromptQueue(until gate: AsyncStream<Void>) {
    lock.withLock { _promptQueueGate = gate }
  }

  func failNextPromptQueue() { lock.withLock { _failNextPromptQueue = true } }

  var queueUpdates: [(id: String, text: String, attachments: [ServerAttachmentRef]?)] {
    lock.withLock { _queueUpdates }
  }

  var queueReorders: [[String]] {
    lock.withLock { _queueReorders }
  }

  var queueDeletes: [String] {
    lock.withLock { _queueDeletes }
  }

  func failNextQueueMutation() {
    lock.withLock { _queueMutationFailuresRemaining += 1 }
  }

  var goalUpdates: [(String?, GoalStatus?, TokenBudgetUpdate)] {
    lock.withLock { _goalUpdates }
  }

  var goalClearCount: Int {
    lock.withLock { _goalClearCount }
  }

  func failNextGoalClear() {
    lock.withLock { _nextGoalClearShouldFail = true }
  }

  var autoResumeCancelCount: Int {
    lock.withLock { _autoResumeCancelCount }
  }

  func failNextAutoResumeCancel() {
    lock.withLock { _nextAutoResumeCancelShouldFail = true }
  }

  var questionAnswers: [(String, String, [String: QuestionAnswerEntry]?)] {
    lock.withLock { _questionAnswers }
  }

  func holdQuestionAnswers(until gate: AsyncStream<Void>) {
    lock.withLock { _questionAnswerGate = gate }
  }

  private var lastBudget: Int? {
    lock.withLock { _lastBudget }
  }

  func emit(_ event: ServerEventEnvelope) {
    yieldEvent(event)
  }

  func botConversation(sessionId: UUID, before: Int?, limit: Int) async throws -> ServerBotConversationPage {
    botConversationPage
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready")
  }

  func listHarnesses() async throws -> [ServerHarness] { [] }
  func info() async throws -> ServerInfo { fatalError("unused") }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    fatalError("unused")
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func listSessions() async throws -> [ServerSession] { [] }

  func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage {
    lock.withLock { _transcriptPageRequests.append((before, limit)) }
    try await transcriptPageFaults.apply()
    if before != nil { olderTranscriptPageRequests.signal() }
    if let before, let olderTranscriptPageHandler { return try await olderTranscriptPageHandler(before) }
    if before == nil, let initialTranscriptPage { return initialTranscriptPage }
    if before != nil, let olderTranscriptPage { return olderTranscriptPage }
    return ServerTranscriptPage(items: [], hasMore: false, eventCursor: detailCursor)
  }

  func transcriptItemDetails(
    id: UUID,
    itemId: String,
    after: String?
  ) async throws -> ServerTranscriptItemDetails {
    let gate = lock.withLock {
      _transcriptDetailRequestCount += 1
      _transcriptDetailCursors.append(after)
      return _transcriptDetailGate
    }
    transcriptDetailRequests.signal()
    if let transcriptDetailHandler { return try await transcriptDetailHandler(itemId, after) }
    if let gate {
      for await _ in gate { break }
    }
    guard let details = transcriptDetailsByItem[itemId] else {
      throw CodevisorServerClientError.httpStatus(404, "")
    }
    return details
  }

  func finishEvents() {
    let continuations = lock.withLock {
      let result = _eventContinuations
      _eventContinuations.removeAll()
      return result
    }
    for continuation in continuations { continuation.finish() }
  }

  func transcriptBodyPage(
    id: UUID, itemId: String, key: String, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    lock.withLock { _transcriptBodyRequests.append(position) }
    guard let transcriptBodyHandler else { throw CodevisorServerClientError.httpStatus(404, "Missing body fixture") }
    return try await transcriptBodyHandler(itemId, key, field, position)
  }

  func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
    let (gate, response, shouldFail) = lock.withLock {
      _promptQueueRequestCount += 1
      defer { _failNextPromptQueue = false }
      return (_promptQueueGate, _promptQueueResponse, _failNextPromptQueue)
    }
    if let gate {
      for await _ in gate { break }
    }
    if shouldFail { throw URLError(.networkConnectionLost) }
    return response
  }

  func updateQueuedPrompt(
    sessionId: UUID,
    queueItemId: String,
    text: String,
    attachments: [ServerAttachmentRef]?
  ) async throws -> ServerPromptQueueItem {
    let shouldFail = lock.withLock {
      guard _queueMutationFailuresRemaining > 0 else {
        _queueUpdates.append((queueItemId, text, attachments))
        return false
      }
      _queueMutationFailuresRemaining -= 1
      return true
    }
    if shouldFail { throw URLError(.networkConnectionLost) }
    return ServerPromptQueueItem(
      id: queueItemId,
      sessionId: sessionId.uuidString,
      text: text,
      createdAt: "2026-08-20T00:00:00.000Z",
      updatedAt: "2026-08-20T00:00:00.000Z"
    )
  }

  func reorderQueuedPrompts(
    sessionId: UUID,
    queueItemIds: [String]
  ) async throws -> [ServerPromptQueueItem] {
    let shouldFail = lock.withLock {
      guard _queueMutationFailuresRemaining > 0 else {
        _queueReorders.append(queueItemIds)
        return false
      }
      _queueMutationFailuresRemaining -= 1
      return true
    }
    if shouldFail { throw URLError(.networkConnectionLost) }
    return queueItemIds.map { id in
      ServerPromptQueueItem(
        id: id,
        sessionId: sessionId.uuidString,
        text: id,
        createdAt: "2026-08-20T00:00:00.000Z",
        updatedAt: "2026-08-20T00:00:00.000Z"
      )
    }
  }

  func deleteQueuedPrompt(sessionId _: UUID, queueItemId: String) async throws {
    let shouldFail = lock.withLock {
      guard _queueMutationFailuresRemaining > 0 else {
        _queueDeletes.append(queueItemId)
        return false
      }
      _queueMutationFailuresRemaining -= 1
      return true
    }
    if shouldFail { throw URLError(.networkConnectionLost) }
  }

}

extension FakeSessionServerClient {
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}

  func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
    lock.withLock { _promptedAttachments.append(attachments) }
    return try await promptSession(id: id, text: text)
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
  ) async throws -> ServerPromptAccepted {
    lock.withLock { _promptedMessageIds.append(messageId) }
    return try await promptSession(id: id, text: text, attachments: attachments)
  }

  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?
  ) async throws -> ServerPromptAccepted {
    lock.withLock { _promptedClientIds.append(clientId) }
    return try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId
    )
  }

  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    lock.withLock {
      _runtimeRequests.append("prompt")
      _promptedTexts.append(text)
    }
    promptRequests.signal()
    if let gate = lock.withLock({ _promptGate }) {
      for await _ in gate { break }
    }
    if let promptFailure { throw promptFailure }
    guard echoOnPrompt else {
      return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    yieldEvent(
      ServerEventEnvelope(
        id: nextEnvelopeId(),
        serverId: "local",
        kind: "session.output",
        subjectId: id.uuidString,
        createdAt: "2026-06-30T00:00:00.000Z",
        payload: .object([
          "role": .string("assistant"),
          "text": .string("Echo: \(text)"),
        ])
      ))
    yieldEvent(
      ServerEventEnvelope(
        id: nextEnvelopeId(),
        serverId: "local",
        kind: "session.updated",
        subjectId: id.uuidString,
        createdAt: "2026-06-30T00:00:01.000Z",
        payload: .object([
          "stopReason": .string("end_turn")
        ])
      ))
    return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }

  private func nextEnvelopeId() -> Int {
    lock.withLock {
      defer { _nextEnvelopeId += 1 }
      return _nextEnvelopeId
    }
  }

  func cancelSession(id: UUID) async throws {
    lock.withLock { _cancelCount += 1 }
  }
  func setSessionMode(id: UUID, modeId: String) async throws {
    lock.withLock { _runtimeRequests.append("mode:\(modeId)") }
  }

  func setSessionConfig(id: UUID, configId: String, value: String) async throws {
    lock.withLock { _runtimeRequests.append("config:\(configId):\(value)") }
    let update = configUpdateReplies.record(configId: configId, value: value)
    if let gate = update.gate {
      for await _ in gate { break }
    }
    if update.fails {
      throw CodevisorServerClientError.invalidResponse
    }
  }

  func setSessionConfigAndReturnOptions(
    id: UUID, configId: String, value: String
  ) async throws -> [SessionConfigOption]? {
    if let handler = configUpdateReplies.handler {
      return try await handler(configId, value)
    }
    try await setSessionConfig(id: id, configId: configId, value: value)
    return nil
  }

  @discardableResult
  func setSessionGoal(
    id: UUID,
    objective: String?,
    status: GoalStatus?,
    tokenBudget: TokenBudgetUpdate
  ) async throws -> SessionGoal {
    if objective == "goal fails" {
      throw CodevisorServerClientError.invalidResponse
    }
    let goal = SessionGoal(
      objective: objective ?? goalUpdates.last?.0 ?? "existing objective",
      status: status ?? .active,
      tokenBudget: {
        switch tokenBudget {
        case .keep: return goalUpdates.isEmpty ? nil : lastBudget
        case .clear: return nil
        case let .set(budget): return budget
        }
      }(),
      createdAt: "2026-07-05T00:00:00.000Z",
      updatedAt: "2026-07-05T00:00:00.000Z"
    )
    lock.withLock {
      _goalUpdates.append((objective, status, tokenBudget))
      _lastBudget = goal.tokenBudget
    }
    return goal
  }

  func clearSessionGoal(id: UUID) async throws {
    let shouldFail = lock.withLock {
      defer { _nextGoalClearShouldFail = false }
      if !_nextGoalClearShouldFail {
        _goalClearCount += 1
      }
      return _nextGoalClearShouldFail
    }
    if shouldFail { throw CodevisorServerClientError.invalidResponse }
  }

  func cancelSessionAutoResume(id: UUID) async throws {
    let shouldFail = lock.withLock {
      defer { _nextAutoResumeCancelShouldFail = false }
      if !_nextAutoResumeCancelShouldFail {
        _autoResumeCancelCount += 1
      }
      return _nextAutoResumeCancelShouldFail
    }
    if shouldFail { throw CodevisorServerClientError.invalidResponse }
  }

  func answerSessionQuestion(
    id: UUID,
    questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws {
    if questionId == "question-fails" {
      throw CodevisorServerClientError.invalidResponse
    }
    lock.withLock { _questionAnswers.append((questionId, outcome, answers)) }
    if let gate = lock.withLock({ _questionAnswerGate }) {
      for await _ in gate { break }
    }
  }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    lock.withLock { _eventSinceValues.append(since) }
    return subscribeEvents(since: since)
  }

  func sessionEventStream(
    id: UUID,
    since: Int
  ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    lock.withLock { _sessionEventSinceValues.append(since) }
    return subscribeEvents(since: since)
  }
}
