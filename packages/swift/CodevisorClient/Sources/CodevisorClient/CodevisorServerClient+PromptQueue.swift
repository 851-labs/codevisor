import Foundation

private struct UpdateQueuedPromptBody: Encodable {
  var text: String
  var attachments: [ServerAttachmentRef]?
}

private struct ReorderQueuedPromptsBody: Encodable {
  var queueItemIds: [String]
}

extension CodevisorServerClient {
  public func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
    try await get("/v1/sessions/\(id.uuidString)/queue")
  }

  public func updateQueuedPrompt(
    sessionId: UUID, queueItemId: String, text: String, attachments: [ServerAttachmentRef]?
  ) async throws -> ServerPromptQueueItem {
    try await send(
      "/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)",
      method: "PATCH",
      body: UpdateQueuedPromptBody(text: text, attachments: attachments)
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

  public func sendQueuedPromptNow(
    sessionId: UUID, queueItemId: String
  ) async throws -> ServerPromptAccepted {
    try await send(
      "/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)/send-now",
      method: "POST",
      body: EmptyBody()
    )
  }

  public func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {
    try await sendNoResponse("/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)", method: "DELETE")
  }
}
