import Foundation

extension SessionModel {
  static let toolCallSearchHydrationLimit = 12

  public func workedItemLocation(ofToolCall toolCallId: String) async -> TranscriptWorkedItemLocation? {
    for itemId in summarizedTurnItemIdsNewestFirst.prefix(Self.toolCallSearchHydrationLimit) {
      if let location = TranscriptWorkedItemLocation.of(toolCall: toolCallId, in: conversation) { return location }
      await transcriptDetails.load(itemId: itemId)
    }
    return TranscriptWorkedItemLocation.of(toolCall: toolCallId, in: conversation)
  }

  private var summarizedTurnItemIdsNewestFirst: [String] {
    conversation.reversed().compactMap { item in
      guard case let .assistant(message) = item, message.turn.hasDeferredWorkedDetails,
        !message.turn.hasHydratedWorkedDetails
      else { return nil }
      return message.turn.deferredDetailItemId
    }
  }
}
