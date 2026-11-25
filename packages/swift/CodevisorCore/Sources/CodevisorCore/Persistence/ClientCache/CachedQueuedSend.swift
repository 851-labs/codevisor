import Foundation

struct CachedQueuedSend: Equatable, Sendable {
  let messageId: UUID
  let text: String
  let attachments: [ServerAttachmentRef]
  let route: String
  let state: String
  let failure: String?

  init(_ unsent: SendQueue.Unsent) {
    messageId = unsent.message.id
    text = unsent.message.text
    attachments = unsent.message.attachments.map(Self.reference)
    route = Self.route(unsent.route)
    (state, failure) = Self.state(unsent.delivery)
  }

  private static func reference(_ attachment: Attachment) -> ServerAttachmentRef {
    ServerAttachmentRef(
      fileId: attachment.fileId, name: attachment.name, mimeType: attachment.mimeType,
      sizeBytes: attachment.sizeBytes, kind: attachment.kind == .image ? .image : .file)
  }

  private static func route(_ route: SendQueue.Route) -> String {
    switch route {
    case .bot: "bot"
    case let .agent(delivery, _): "agent.\(delivery.rawValue)"
    }
  }

  private static func state(_ delivery: TranscriptDelivery?) -> (String, String?) {
    switch delivery {
    case nil: ("queued", nil)
    case .sending: ("sending", nil)
    case .awaitingStep: ("awaiting_step", nil)
    case let .failed(reason): ("failed", reason)
    }
  }
}
