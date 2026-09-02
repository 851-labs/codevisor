import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

extension ServerSessionTransport {
  public func prompt(
    _ text: String,
    attachments: [Attachment] = [],
    messageId: String? = nil
  ) async throws -> ServerPromptAccepted {
    try await client.promptSession(
      id: sessionId,
      text: text,
      attachments: attachments.map(\.serverRef),
      messageId: messageId
    )
  }

  public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    try await client.uploadFile(name: name, mimeType: mimeType, data: data)
  }

  public func fileData(id: String) async throws -> Data {
    try await client.fileData(id: id)
  }

  public func fileData(path: String) async throws -> Data {
    try await client.fileData(sessionId: sessionId, path: path)
  }

  public func updateQueuedPrompt(id: String, text: String) async throws -> ServerPromptQueueItem {
    try await client.updateQueuedPrompt(sessionId: sessionId, queueItemId: id, text: text)
  }

  public func reorderQueuedPrompts(ids: [String]) async throws -> [ServerPromptQueueItem] {
    try await client.reorderQueuedPrompts(sessionId: sessionId, queueItemIds: ids)
  }

  public func deleteQueuedPrompt(id: String) async throws {
    try await client.deleteQueuedPrompt(sessionId: sessionId, queueItemId: id)
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
