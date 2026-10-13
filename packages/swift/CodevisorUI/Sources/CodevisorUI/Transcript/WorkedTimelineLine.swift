import ACPKit
import CodevisorCore
import SwiftUI
import TranscriptKit

/// A worked section's work, as a line on its timeline (notes are Markdown
/// rows beside the same rail): a subdued few-word summary that opens to its
/// calls, or a lone call's own label that opens to its output. Its header
/// brightens on hover, as the calls inside it do, and shows a chevron in
/// place of its icon while hovered or open.
struct WorkedTimelineLine<Detail: View>: View {
  let item: WorkedItem
  let isFirst: Bool
  let isLast: Bool
  let isTurnActive: Bool
  /// The agents the turn is blocked on (see `awaitedAgentCalls`).
  var awaitedAgents: [ToolCall] = []
  /// The item's ordinary rendering, for what a subagent line opens to.
  let detail: (WorkedItem) -> Detail

  @State private var isHovering = false
  @State private var totalsCache = DiffTotalsCache()
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange

  var body: some View {
    let store = disclosureStore ?? .previews
    let disclosure = store.toolGroupDisclosure(id: "timeline:\(item.id)")
    let isExpanded = disclosure.isExpanded && isDisclosable
    WorkedTimelineRail(
      isFirst: isFirst, isLast: isLast,
      onHeaderHover: { isHovering = $0 && isDisclosable },
      onHeaderTap: isDisclosable
        ? {
          let change = {
            disclosure.userToggled()
            // A lone call opens as its own row would, so if another call
            // joins it, it stays open in the group the line becomes.
            if let call = loneCall {
              store.setExpanded(.toolCall(call.toolCallId), disclosure.isExpanded)
            }
          }
          performAnchoredDisclosureChange?(change) ?? change()
        } : nil
    ) {
      WorkedTimelineNode(item: item, showsChevron: isHovering || isExpanded, isExpanded: isExpanded)
    } line: {
      workLine(isExpanded: isExpanded)
    } expanded: {
      if isExpanded {
        opened
          .environment(\.toolRowsHighlightOnHover, true)
          .padding(.top, 2)
          .padding(.bottom, 6)
      }
    }
  }

  /// A group's only call, which the line stands in for.
  private var loneCall: ToolCall? {
    if case let .toolGroup(group) = item, group.calls.count == 1 { group.calls[0] } else { nil }
  }

  private var isDisclosable: Bool {
    loneCall?.hasPresentableDetails ?? true
  }

  @ViewBuilder
  private func workLine(isExpanded: Bool) -> some View {
    let calls = item.timelineCalls
    HStack(spacing: 6) {
      if let call = loneCall {
        let totals = totalsCache.totals(for: call)
        Text(call.displayTitle(diffTotals: totals))
          .foregroundStyle(isHovering ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .shimmering(isTurnActive && !call.isSettled)
        if let totals {
          DiffCounter(totals: totals)
        }
      } else {
        let agents = item.timelineAgents
        let isWaiting = agents.contains { agent in awaitedAgents.contains { $0.toolCallId == agent.toolCallId } }
        Text(WorkedTimelineText.title(calls: calls, agents: agents, awaited: awaitedAgents))
          .foregroundStyle(isHovering ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .shimmering((isWaiting || (isTurnActive && calls.contains { !$0.isSettled })) && !isExpanded)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var opened: some View {
    if let call = loneCall {
      ToolCallDetails(call: call)
    } else if case let .toolGroup(group) = item {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(group.calls) { call in
          ToolCallRow(call: call, isTurnActive: isTurnActive)
        }
      }
    } else {
      detail(item)
    }
  }
}

extension WorkedItem {
  fileprivate var timelineCalls: [ToolCall] {
    if case let .toolGroup(group) = self { group.calls } else { [] }
  }

  fileprivate var timelineAgents: [ToolCall] {
    if case let .subagents(_, calls) = self { calls } else { [] }
  }
}
