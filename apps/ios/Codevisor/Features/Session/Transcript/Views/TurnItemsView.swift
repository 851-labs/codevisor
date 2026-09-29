import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Worked items in stream order: reasoning text, tool groups, and subagent
/// rows (a subagent's thread opens as its own read-only screen).
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
      case let .subagent(_, call):
        // One row; the thread pushes as a read-only chat.
        SubagentRow(call: call, isTurnActive: isTurnActive)
      }
    }
    .font(.callout)
  }
}
