import CoreGraphics

enum TranscriptEventRowProjection {
  static let markerEstimatedHeight: CGFloat = 24

  static func append(_ item: ConversationItem, to rows: inout [TranscriptPresentationRow]) -> Bool {
    guard let row = row(for: item, inBotConversation: false) else { return false }

    rows.append(row)
    return true
  }

  static func row(
    for item: ConversationItem, inBotConversation: Bool, spacingAfter: CGFloat? = nil
  ) -> TranscriptPresentationRow? {
    guard case let .user(message) = item, let marker = TranscriptEventMarker(message: message) else { return nil }

    return .init(
      id: .eventMarker(message.id),
      content: .eventMarker(marker, inBotConversation: inBotConversation),
      estimatedHeight: markerEstimatedHeight,
      spacingAfter: spacingAfter
    )
  }
}
