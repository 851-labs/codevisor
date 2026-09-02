import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// The macOS TranscriptItemsView: worked items in stream order, recursing
/// into subagent sections.
struct TurnItemsView: View {
  @Environment(\.theme) private var theme
  let items: [WorkedItem]
  let turn: AssistantTurn
  let turnId: UUID
  let depth: Int
  let isTurnActive: Bool
  let animationPresentation: StreamingTextAnimationPresentation
  let animationEnabled: Bool
  var parentToolCallID: String? = nil

  private static let maxNestingDepth = 3

  var body: some View {
    let trailingToolCallIds = depth == 0 && isTurnActive ? turn.trailingToolCallIds : []
    ForEach(items) { item in
      switch item {
      case let .text(entryID, markdown):
        StreamingMarkdownView(
          markdown,
          isComplete: !isTurnActive,
          foregroundColor: theme.textSecondary,
          streamID: streamID(for: entryID),
          animationPresentation: animationPresentation,
          animationEnabled: animationEnabled
        )
      case let .toolGroup(group):
        ToolGroupView(
          group: group,
          isTurnActive: isTurnActive,
          followsLatestWork: depth == 0 && isTurnActive
            && (group.calls.last.map { trailingToolCallIds.contains($0.toolCallId) } ?? false),
          automaticDisclosurePolicy: depth == 0
            ? .followLatestWork
            : .remainExpandedAfterActivity
        )
      case let .subagent(_, call):
        if depth + 1 < Self.maxNestingDepth {
          SubagentSection(
            call: call,
            turn: turn,
            turnId: turnId,
            depth: depth,
            isTurnActive: isTurnActive,
            animationPresentation: animationPresentation,
            animationEnabled: animationEnabled
          )
        } else {
          ToolCallRow(call: call, isTurnActive: isTurnActive)
        }
      case let .contextCompaction(_, status):
        switch status {
        case .started:
          ShimmeringText.compactingContext
        case .completed:
          AgentStatusText.contextCompacted
        case .failed:
          EmptyView()
        }
      }
    }
    .font(.callout)
  }

  private func streamID(for entryID: String) -> String {
    if let parentToolCallID {
      return TranscriptStreamingTextIdentity.subagent(
        turnID: turnId,
        parentToolCallID: parentToolCallID,
        entryID: entryID
      )
    }
    return TranscriptStreamingTextIdentity.main(turnID: turnId, entryID: entryID)
  }
}
