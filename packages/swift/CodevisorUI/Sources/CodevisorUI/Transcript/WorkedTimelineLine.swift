import ACPKit
import CodevisorCore
import SwiftUI
import TranscriptKit

struct WorkedTimelineLine<Detail: View>: View {
  let item: WorkedItem
  let isFirst: Bool
  let isLast: Bool
  let isTurnActive: Bool
  var awaitedAgents: [ToolCall] = []
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
