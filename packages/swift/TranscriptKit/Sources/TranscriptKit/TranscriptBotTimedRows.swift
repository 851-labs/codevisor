import CoreGraphics
import Foundation

enum TranscriptBotTimedRows {
  struct Entry {
    let askedAt: Date?
    let row: TranscriptPresentationRow
  }

  static func entries(in input: TranscriptProjectionInput, spacingAfter: CGFloat) -> [Entry] {
    let items = input.settledConversation + [input.activeItem].compactMap(\.self)
    return items.indices.flatMap { index in
      entries(for: items[index], startingTurnAt: nextTurnStart(after: index, in: items), spacingAfter: spacingAfter)
    }
  }

  private static func entries(
    for item: ConversationItem, startingTurnAt turnStart: Date?, spacingAfter: CGFloat
  )
    -> [Entry]
  {
    switch item {
    case .user:
      let row = TranscriptEventRowProjection.row(for: item, inBotConversation: true, spacingAfter: spacingAfter)
      return row.map { [Entry(askedAt: turnStart, row: $0)] } ?? []
    case let .assistant(message):
      return bubbleRows(message.turn, spacingAfter: spacingAfter).map { Entry(askedAt: message.turn.endedAt, row: $0) }
    }
  }

  private static func nextTurnStart(after index: Int, in items: [ConversationItem]) -> Date? {
    items[(index + 1)...].lazy.compactMap { item -> AssistantMessage? in
      guard case let .assistant(message) = item else { return nil }
      return message
    }.first?.turn.startedAt
  }

  private static func bubbleRows(_ turn: AssistantTurn, spacingAfter: CGFloat) -> [TranscriptPresentationRow] {
    turn.setupRequests.map { .setupRequest($0, inBotConversation: true, spacingAfter: spacingAfter) }
      + turn.interactions.shownInTranscript.map {
        .interaction($0, inBotConversation: true, spacingAfter: spacingAfter)
      }
  }
}
