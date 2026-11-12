import SwiftUI
import TranscriptKit

struct TranscriptWorkedLineRow: View {
  let line: TranscriptWorkedLine

  var body: some View {
    switch line.content {
    case .thinking:
      WorkedTimelineThinking(isFirst: line.isFirst)
    case let .earlierHistory(count):
      WorkedTimelineEarlierHistory(
        count: count,
        messageID: line.reference.messageID,
        kind: line.reference.section
      )
    case let .item(item):
      WorkedTimelineLine(
        item: item,
        isFirst: line.isFirst,
        isLast: line.isLast,
        isTurnActive: line.isTurnActive,
        awaitedAgents: line.awaitedAgents
      )
    }
  }
}
