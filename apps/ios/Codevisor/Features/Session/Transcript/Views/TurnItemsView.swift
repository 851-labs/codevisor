import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TurnItemsView: View {
  @Environment(\.theme) private var theme
  let items: [WorkedItem]
  let turnId: UUID
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
          foregroundColor: theme.textPrimary,
          streamID: TranscriptStreamingTextIdentity.main(turnID: turnId, entryID: entryID),
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
    .font(.callout)
  }
}
