import Foundation

public extension CodevisorServerClienting {
  func promptSession(
    id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?,
    clientId: String?, delivery: ServerPromptDelivery?, clientActionId _: String
  ) async throws -> ServerPromptAccepted {
    guard let delivery else {
      return try await promptSession(
        id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId
      )
    }
    return try await promptSession(
      id: id, text: text, attachments: attachments, messageId: messageId, clientId: clientId,
      delivery: delivery
    )
  }
}
