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

  private static var iconFont: Font {
    #if os(iOS)
      .subheadline
    #else
      .callout
    #endif
  }

  private static var iconColumnWidth: CGFloat {
    #if os(iOS)
      // The terminal symbol is slightly wider than the old 16pt column.
      // Keep its ink inside the clipped transcript-row host.
      18
    #else
      16
    #endif
  }

  private static var headerSpacing: CGFloat {
    #if os(iOS)
      // Preserve the existing 24pt icon-column-plus-gap label inset.
      6
    #else
      8
    #endif
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

  public var body: some View {
    let disclosure = store.toolGroupDisclosure(id: group.id)
    let isExpanded = disclosure.isExpanded
    let header = ToolGroupHeaderPresentation(
      group: group,
      isExpanded: isExpanded,
      isTurnActive: isTurnActive,
      totalsCache: totalsCache
    )

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Self.headerSpacing) {
        // Pinned to the first call's icon — a group's icon flipping
        // as more calls stream in reads as UI churn.
        Image(systemName: ToolCallSummary.symbol(group.calls.first.map { [$0] } ?? []))
          // One notch under the row label on both platforms: macOS
          // pairs a 12pt callout icon with 13pt body text; iOS rows
          // label at callout 16, so the icon sits at subheadline 15.
          .font(Self.iconFont)
          .foregroundStyle(.secondary)
          .frame(width: Self.iconColumnWidth)
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

      TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(group.calls) { call in
            ToolCallRow(call: call, isTurnActive: isTurnActive)
          }
        }
        .padding(.leading, 24)
        .padding(.top, 8)
      }
    }
  }
}

/// Collapsed live groups expose the latest call; opening or finishing the
/// group restores its summary. The same activity bit controls the shimmer.
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
