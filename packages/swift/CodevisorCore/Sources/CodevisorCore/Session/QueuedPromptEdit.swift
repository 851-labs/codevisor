import Foundation

struct QueuedPromptEdit: Equatable {
  var queueItemID: String
  let stashedText: String
  let stashedAttachments: [ComposerAttachment]
}

extension ComposerAttachment {
  init(queued ref: ServerAttachmentRef) {
    self.init(
      id: UUID(),
      name: ref.name,
      mimeType: ref.mimeType,
      kind: ref.attachment.kind,
      state: .uploaded(ref)
    )
  }
}
