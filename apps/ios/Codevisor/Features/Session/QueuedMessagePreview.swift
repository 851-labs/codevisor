import Foundation
import CodevisorCore

struct QueuedMessagePreview: Equatable, Identifiable {
  let id: String
  let text: String
}

extension SessionController {
  var queuedMessagePreviews: [QueuedMessagePreview] {
    queuedPrompts.map { QueuedMessagePreview(id: $0.id, text: $0.text) }
      + unsentQueuedMessages.map { QueuedMessagePreview(id: $0.id.uuidString.lowercased(), text: $0.text) }
  }
}
