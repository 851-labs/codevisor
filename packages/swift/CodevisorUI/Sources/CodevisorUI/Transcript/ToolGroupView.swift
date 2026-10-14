import SwiftUI
import ACPKit
import CodevisorCore

public struct ToolGroupView: View {
  let group: ToolCallGroup
  var isTurnActive: Bool = false

  public init(
    group: ToolCallGroup,
    isTurnActive: Bool = false
  ) {
    self.group = group
    self.isTurnActive = isTurnActive
  }
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var totalsCache = DiffTotalsCache()

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

  public var body: some View {
    if let solo = group.soloCall {
      ToolCallRow(call: solo, isTurnActive: isTurnActive)
    } else {
      groupBody
    }
  }

  @ViewBuilder
  private var groupBody: some View {
    let disclosure = store.toolGroupDisclosure(id: group.id)
    let isExpanded = disclosure.isExpanded
    let header = ToolGroupHeaderPresentation(
      group: group,
      isExpanded: isExpanded,
      isTurnActive: isTurnActive,
      totalsCache: totalsCache
    )

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(header.title)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.tail)
          .foregroundStyle(.secondary)
          .shimmering(header.isShimmering)
        TranscriptDisclosureChevron(expanded: isExpanded)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        let change = { disclosure.userToggled() }
        performAnchoredDisclosureChange?(change) ?? change()
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        let change = { disclosure.userToggled() }
        performAnchoredDisclosureChange?(change) ?? change()
      }

      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(group.calls) { call in
            ToolCallRow(call: call, isTurnActive: isTurnActive)
          }
        }
        .padding(.top, 8)
      }
    }
  }
}

struct ToolGroupHeaderPresentation {
  let title: String
  let isShimmering: Bool

  @MainActor
  init(group: ToolCallGroup, isExpanded: Bool, isTurnActive: Bool, totalsCache: DiffTotalsCache) {
    isShimmering = !isExpanded && isTurnActive && group.hasUnsettledCall
    if isShimmering, let latestCall = group.calls.last {
      title = latestCall.displayTitle(diffTotals: totalsCache.totals(for: latestCall))
    } else {
      title = ToolCallSummary.describe(group.calls)
    }
  }
}

extension ToolCallGroup {
  var soloCall: ToolCall? {
    guard calls.count == 1, let call = calls.first else { return nil }
    return call.integrationDescription != nil || call.codevisorGatewayOperation == .skills ? call : nil
  }
}

#Preview {
  ToolGroupView(
    group: ToolCallGroup(calls: [
      ToolCall(
        toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm\"", kind: .execute, status: .completed,
        content: [.content(.text("no matches found"))]),
      ToolCall(toolCallId: "2", title: "Searched for files", kind: .search, status: .completed),
      ToolCall(toolCallId: "3", title: "Ran pwd && rg --files", kind: .execute, status: .completed),
    ])
  )
  .padding()
  .frame(width: 520)
}
