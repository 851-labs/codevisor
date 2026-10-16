import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

struct TranscriptItemsView: View {
  let items: [WorkedItem]
  let turnID: UUID
  let isTurnActive: Bool
  let animationPresentation: StreamingTextAnimationPresentation
  let animationEnabled: Bool

  var body: some View {
    ForEach(items) { item in
      switch item {
      case let .text(entryID, markdown):
        StreamingMarkdownView(
          markdown,
          isComplete: !isTurnActive,
          foregroundColor: .primary,
          streamID: TranscriptStreamingTextIdentity.main(turnID: turnID, entryID: entryID),
          animationPresentation: animationPresentation,
          animationEnabled: animationEnabled
        )
      case let .toolGroup(group):
        ToolGroupView(
          group: group,
          isTurnActive: isTurnActive
        )
      case let .subagents(_, calls):
        SubagentChips(calls: calls, isTurnActive: isTurnActive)
      }
    }
  }
}
