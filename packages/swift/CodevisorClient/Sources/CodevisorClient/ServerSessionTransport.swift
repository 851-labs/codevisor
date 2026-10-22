import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionTransport: Sendable {
  public static let liveOnlyEventCursor = 9_007_199_254_740_991

  let client: any CodevisorServerClienting
  let sessionId: UUID

  public init(client: any CodevisorServerClienting, sessionId: UUID) {
    self.client = client
    self.sessionId = sessionId
  }

  private var resolver: ServerTranscriptResolver { ServerTranscriptResolver(transport: self) }

  private var eventStream: ServerSessionEventStream { ServerSessionEventStream(transport: self) }

  public func usageLimits() async throws -> ServerHarnessUsageLimits {
    try await client.sessionUsageLimits(id: sessionId)
  }

  public func botConversation(before: Int?, limit: Int) async throws -> ServerBotConversationPage {
    try await client.botConversation(sessionId: sessionId, before: before, limit: limit)
  }

  public func promptQueue() async throws -> [ServerPromptQueueItem] {
    try await client.promptQueue(id: sessionId)
  }

  public func transcriptPage(before: String? = nil, limit: Int = 32) async throws -> TranscriptHistoryPage {
    historyPage(from: try await client.transcriptPage(id: sessionId, before: before, limit: limit))
  }

  public func historyPage(from page: ServerTranscriptPage) -> TranscriptHistoryPage {
    ServerTranscriptHistoryMapper.historyPage(from: page)
  }

  public func completeHistoryPage(
    _ page: TranscriptHistoryPage, before: String? = nil, limit: Int = 32
  ) async throws -> TranscriptHistoryPage {
    try await resolver.completeHistoryPage(page, before: before, limit: limit)
  }

  public func transcriptBodyPage(
    resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    try await client.transcriptBodyPage(
      id: sessionId, itemId: resource.itemId, key: resource.entryKey, field: field, position: position)
  }

  @concurrent
  public func transcriptDetailEvents(
    itemId: String
  ) async throws -> (details: ServerTranscriptItemDetails, events: [ServerSessionStreamEvent]) {
    try await resolver.transcriptDetailEvents(itemId: itemId)
  }

  public func transcriptDetails(itemId: String) async throws -> ServerTranscriptItemDetails {
    try await resolver.transcriptDetails(itemId: itemId)
  }

  public func streamEvents(
    since: Int = Self.liveOnlyEventCursor
  ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    ServerSessionEventStream.droppingCursors(streamEnvelopes(since: since))
  }

  public func streamEnvelopes(
    since: Int = Self.liveOnlyEventCursor
  ) -> AsyncThrowingStream<ServerSessionStreamEnvelope, any Error> {
    eventStream.envelopes(since: since)
  }

  public func legacyStreamEvents(
    since: Int
  ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
    ServerSessionEventStream.droppingCursors(legacyStreamEnvelopes(since: since))
  }

  public func legacyStreamEnvelopes(
    since: Int
  ) -> AsyncThrowingStream<ServerSessionStreamEnvelope, any Error> {
    eventStream.legacyEnvelopes(since: since)
  }

  public func prompt(
    _ text: String,
    attachments: [Attachment] = [],
    messageId: String? = nil,
    clientId: String? = nil
  ) async throws -> ServerPromptAccepted {
    try await client.promptSession(
      id: sessionId,
      text: text,
      attachments: attachments.map(\.serverRef),
      messageId: messageId,
      clientId: clientId
    )
  }

  public func prompt(
    _ text: String,
    attachments: [Attachment] = [],
    messageId: String? = nil,
    clientId: String? = nil,
    delivery: ServerPromptDelivery
  ) async throws -> ServerPromptAccepted {
    try await client.promptSession(
      id: sessionId,
      text: text,
      attachments: attachments.map(\.serverRef),
      messageId: messageId,
      clientId: clientId,
      delivery: delivery
    )
  }

  public func prompt(
    _ text: String,
    attachments: [Attachment] = [],
    messageId: String,
    clientId: String? = nil,
    delivery: ServerPromptDelivery?,
    clientActionId: String
  ) async throws -> ServerPromptAccepted {
    try await client.promptSession(
      id: sessionId,
      text: text,
      attachments: attachments.map(\.serverRef),
      messageId: messageId,
      clientId: clientId,
      delivery: delivery,
      clientActionId: clientActionId
    )
  }

  public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    try await client.uploadFile(name: name, mimeType: mimeType, data: data)
  }

  public func uploadFile(name: String, mimeType: String, fileURL: URL) async throws -> ServerFileMetadata {
    try await client.uploadFile(name: name, mimeType: mimeType, fileURL: fileURL)
  }

  public func fileData(id: String) async throws -> Data {
    try await client.fileData(id: id)
  }

  public func fileData(path: String) async throws -> Data {
    try await client.fileData(sessionId: sessionId, path: path)
  }

  public func updateQueuedPrompt(
    id: String, text: String, attachments: [Attachment]? = nil
  ) async throws -> ServerPromptQueueItem {
    try await client.updateQueuedPrompt(
      sessionId: sessionId, queueItemId: id, text: text, attachments: attachments?.map(\.serverRef))
  }

  public func reorderQueuedPrompts(ids: [String]) async throws -> [ServerPromptQueueItem] {
    try await client.reorderQueuedPrompts(sessionId: sessionId, queueItemIds: ids)
  }

  public func deleteQueuedPrompt(id: String) async throws {
    try await client.deleteQueuedPrompt(sessionId: sessionId, queueItemId: id)
  }

  public func sendQueuedPromptNow(id: String) async throws -> ServerPromptAccepted {
    try await client.sendQueuedPromptNow(sessionId: sessionId, queueItemId: id)
  }

  public func cancel() async throws {
    try await client.cancelSession(id: sessionId)
  }

  public func setMode(_ modeId: String) async throws {
    try await client.setSessionMode(id: sessionId, modeId: modeId)
  }

  public func setConfigOption(
    configId: String,
    value: String
  ) async throws -> [SessionConfigOption]? {
    try await client.setSessionConfigAndReturnOptions(
      id: sessionId,
      configId: configId,
      value: value
    )
  }

  @discardableResult
  public func setGoal(
    objective: String? = nil,
    status: GoalStatus? = nil,
    tokenBudget: TokenBudgetUpdate = .keep
  ) async throws -> SessionGoal {
    try await client.setSessionGoal(
      id: sessionId,
      objective: objective,
      status: status,
      tokenBudget: tokenBudget
    )
  }

  public func clearGoal() async throws {
    try await client.clearSessionGoal(id: sessionId)
  }

  public func cancelAutoResume() async throws {
    try await client.cancelSessionAutoResume(id: sessionId)
  }

  public func answerQuestion(
    id questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws {
    try await client.answerSessionQuestion(
      id: sessionId,
      questionId: questionId,
      outcome: outcome,
      answers: answers
    )
  }
}
