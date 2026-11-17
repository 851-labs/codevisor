import CoreGraphics

enum TranscriptEventRowProjection {
  static let markerEstimatedHeight: CGFloat = 24

  static func append(_ item: ConversationItem, to rows: inout [TranscriptPresentationRow]) -> Bool {
    guard let marker = marker(of: item) else { return false }

    rows.append(row(for: marker, inBotConversation: false))
    return true
  }

  static func botFeedRow(for item: ConversationItem, spacingAfter: CGFloat) -> TranscriptPresentationRow? {
    guard let marker = marker(of: item)?.withoutAgentStatuses else { return nil }

    return row(for: marker, inBotConversation: true, spacingAfter: spacingAfter)
  }

  private static func marker(of item: ConversationItem) -> TranscriptEventMarker? {
    guard case let .user(message) = item else { return nil }

    return TranscriptEventMarker(message: message)
  }

  private static func row(
    for marker: TranscriptEventMarker, inBotConversation: Bool, spacingAfter: CGFloat? = nil
  ) -> TranscriptPresentationRow {
    .init(
      id: .eventMarker(marker.messageID),
      content: .eventMarker(marker, inBotConversation: inBotConversation),
      estimatedHeight: markerEstimatedHeight,
      spacingAfter: spacingAfter
    )
  }
}
