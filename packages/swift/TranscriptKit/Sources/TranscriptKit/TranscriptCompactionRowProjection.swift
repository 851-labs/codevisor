import CoreGraphics

enum TranscriptCompactionRowProjection {
  static let markerEstimatedHeight: CGFloat = 24

  static func append(_ message: AssistantMessage, to rows: inout [TranscriptPresentationRow]) -> Bool {
    guard message.turn.compactedContext else { return false }

    rows.append(
      .init(id: .compactionMarker(message.id), content: .compactionMarker, estimatedHeight: markerEstimatedHeight))
    return true
  }
}
