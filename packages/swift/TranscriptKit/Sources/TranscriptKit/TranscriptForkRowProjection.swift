import CoreGraphics

enum TranscriptForkRowProjection {
  static let markerEstimatedHeight: CGFloat = 24

  static func append(_ item: ConversationItem, to rows: inout [TranscriptPresentationRow]) -> Bool {
    guard case let .user(message) = item, message.isForkMarker else { return false }

    rows.append(
      .init(id: .forkMarker(message.id), content: .forkMarker(message.text), estimatedHeight: markerEstimatedHeight))
    return true
  }
}
