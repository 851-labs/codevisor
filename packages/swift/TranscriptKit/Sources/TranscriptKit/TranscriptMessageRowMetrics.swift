import CoreGraphics
import Foundation

enum TranscriptMessageRowMetrics {
  static func optimisticMeasurementRevision(for message: UserMessage) -> Int {
    var hasher = Hasher()
    hasher.combine(3)
    hasher.combine(message.text.utf8.count)
    hasher.combine(message.attachments.count)
    for attachment in message.attachments {
      hasher.combine(attachment.id)
      hasher.combine(attachment.sizeBytes)
    }
    return hasher.finalize()
  }

  static func attachmentMeasurementRevision(
    _ attachment: TranscriptAssistantAttachment
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(attachment.file.id)
    hasher.combine(attachment.label)
    return hasher.finalize()
  }

  static func estimatedHeight(for item: ConversationItem) -> CGFloat {
    switch item {
    case let .user(message):
      max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
    case .assistant:
      320
    }
  }

  static func measurementRevision(
    for item: ConversationItem,
    waitingOnBackgroundTask: String?
  ) -> Int {
    var hasher = Hasher()
    switch item {
    case let .user(message):
      hasher.combine(0)
      hasher.combine(message.text.utf8.count)
      hasher.combine(message.attachments.count)
      for attachment in message.attachments {
        hasher.combine(attachment.id)
        hasher.combine(attachment.sizeBytes)
      }
    case let .assistant(message):
      let turn = message.turn
      hasher.combine(1)
      hasher.combine(turn.entries.count)
      hasher.combine(turn.isGenerating)
      hasher.combine(turn.detailRevision)
      hasher.combine(turn.hasDeferredWorkedDetails)
      hasher.combine(turn.contextCompactionStatus?.rawValue)
      hasher.combine(turn.planDocument?.utf8.count ?? 0)
      hasher.combine(turn.stopDetail?.utf8.count ?? 0)
      hasher.combine(turn.subagentActivityFingerprint)
      hasher.combine(turn.attachments.count)
      for attachment in turn.attachments {
        hasher.combine(attachment.id)
        hasher.combine(attachment.sizeBytes)
      }
    }
    hasher.combine(waitingOnBackgroundTask)
    return hasher.finalize()
  }

  static func chromeEstimatedHeight(
    _ message: AssistantMessage,
    slice: TranscriptAssistantChromeSlice,
    waitingOnBackgroundTask: String?
  ) -> CGFloat {
    guard slice == .epilogue else { return 32 }
    let showsFooter =
      waitingOnBackgroundTask != nil || (!message.turn.isGenerating && message.turn.stopDetail != nil)
    return showsFooter ? 32 : 1
  }
}
