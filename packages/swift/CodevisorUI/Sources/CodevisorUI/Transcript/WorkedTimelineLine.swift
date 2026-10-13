import ACPKit
import CodevisorCore
import SwiftUI
import TranscriptKit

/// A worked section's work, as a line on its timeline (notes are Markdown
/// rows beside the same rail): a subdued few-word summary that opens to its
/// calls. Its header brightens on hover, as the calls inside it do, and
/// shows a chevron in place of its icon while hovered or open.
struct WorkedTimelineLine<Detail: View>: View {
  let item: WorkedItem
  let isFirst: Bool
  let isLast: Bool
  let isTurnActive: Bool
  /// The item's ordinary rendering, for what a subagent line opens to.
  let detail: (WorkedItem) -> Detail

  @State private var isHovering = false
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange

  var body: some View {
    let disclosure = (disclosureStore ?? .previews).toolGroupDisclosure(id: "timeline:\(item.id)")
    let isExpanded = disclosure.isExpanded
    WorkedTimelineRail(
      isFirst: isFirst, isLast: isLast,
      onHeaderHover: { isHovering = $0 },
      onHeaderTap: {
        let change = { disclosure.userToggled() }
        performAnchoredDisclosureChange?(change) ?? change()
      }
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

  private func workLine(isExpanded: Bool) -> some View {
    let calls = item.timelineCalls
    return Text(WorkedTimelineText.title(calls: calls, agents: item.agentCount))
      .foregroundStyle(isHovering ? .primary : .secondary)
      .lineLimit(1)
      .shimmering(isTurnActive && calls.contains { !$0.isSettled } && !isExpanded)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var opened: some View {
    if case let .toolGroup(group) = item {
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

  fileprivate var agentCount: Int {
    if case let .subagents(_, calls) = self { calls.count } else { 0 }
  }
}
