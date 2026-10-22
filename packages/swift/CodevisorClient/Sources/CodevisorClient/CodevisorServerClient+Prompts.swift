import Foundation

private struct PromptBody: Encodable {
  var text: String
  var clientActionId = UUID().uuidString
  var attachments: [ServerAttachmentRef]?
  var messageId: String?
  var clientId: String?
  var delivery: ServerPromptDelivery?
}

extension CodevisorServerClient {
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
    try await sendPrompt(
      id: id,
      body: PromptBody(
        text: text,
        attachments: attachments.isEmpty ? nil : attachments,
        messageId: messageId,
        clientId: clientId
      )
    )
  }

  public func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery
  ) async throws -> ServerPromptAccepted {
    try await sendPrompt(
      id: id,
      body: PromptBody(
        text: text,
        attachments: attachments.isEmpty ? nil : attachments,
        messageId: messageId,
        clientId: clientId,
        delivery: delivery
      )
    )
  }

  public func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery?, clientActionId: String
  ) async throws -> ServerPromptAccepted {
    try await sendPrompt(
      id: id,
      body: PromptBody(
        text: text,
        clientActionId: clientActionId,
        attachments: attachments.isEmpty ? nil : attachments,
        messageId: messageId,
        clientId: clientId,
        delivery: delivery
      )
    )
  }

  private func sendPrompt(id: UUID, body: PromptBody) async throws -> ServerPromptAccepted {
    try await send("/v1/sessions/\(id.uuidString)/prompt", method: "POST", body: body)
  }
}
