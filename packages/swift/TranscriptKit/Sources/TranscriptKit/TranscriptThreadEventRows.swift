enum TranscriptThreadEventRows {
  static func append(_ row: TranscriptPresentationRow, to rows: inout [TranscriptPresentationRow]) {
    guard let merged = merged(row, into: rows.last) else {
      rows.append(row)
      return
    }
    rows[rows.count - 1] = merged
  }

  private static func merged(
    _ row: TranscriptPresentationRow, into last: TranscriptPresentationRow?
  ) -> TranscriptPresentationRow? {
    guard let last, case let .eventMarker(open, inBotConversation) = last.content,
      case let .eventMarker(next, _) = row.content,
      let threadID = open.threadID, next.threadID == threadID
    else { return nil }

    return .init(
      id: last.id,
      content: .eventMarker(open.merging(next), inBotConversation: inBotConversation),
      estimatedHeight: last.estimatedHeight,
      spacingAfter: row.spacingAfter
    )
  }
}
