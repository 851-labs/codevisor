import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

/// Renders a list of worked items — reasoning text, tool groups, and subagent
/// rows. A subagent's own thread is not nested here: its row opens the thread
/// as a read-only chat pane.
struct TranscriptItemsView: View {
  let items: [WorkedItem]
  @Environment(\.theme) private var theme
  let turnID: UUID
  let isTurnActive: Bool
  let animationPresentation: StreamingTextAnimationPresentation
  let animationEnabled: Bool

  var body: some View {
    ForEach(items) { item in
      switch item {
      case let .text(entryID, markdown):
        // Streaming render mode while the turn is live: commentary
        // spans stream the same way the final answer does, so they get
        // the same O(growing block) per-flush cost bound.
        StreamingMarkdownView(
          markdown,
          isComplete: !isTurnActive,
          foregroundColor: theme.textPrimary,
          streamID: TranscriptStreamingTextIdentity.main(turnID: turnID, entryID: entryID),
          animationPresentation: animationPresentation,
          animationEnabled: animationEnabled
        )
      case let .toolGroup(group):
        ToolGroupView(
          group: group,
          isTurnActive: isTurnActive
        )
      case let .subagent(_, call):
        // One row; the thread opens as a read-only pane beside the chat.
        SubagentRow(call: call, isTurnActive: isTurnActive)
      }
    }
  }
}
