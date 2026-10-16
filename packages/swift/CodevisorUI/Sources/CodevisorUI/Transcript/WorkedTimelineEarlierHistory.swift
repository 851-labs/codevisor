import CodevisorCore
import SwiftUI
import TranscriptKit

struct WorkedTimelineEarlierHistory: View {
  let count: Int
  let messageID: UUID
  let kind: TranscriptWorkedSectionKind

  @State private var isHovering = false
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  var body: some View {
    if count > 0 {
      WorkedTimelineRail(
        isFirst: true, isLast: false,
        onHeaderHover: { isHovering = $0 },
        onHeaderTap: reveal
      ) {
        Image(systemName: "ellipsis")
          .font(.caption)
          .foregroundStyle(isHovering ? .primary : .secondary)
      } line: {
        Text(count == 1 ? "Show 1 earlier step" : "Show \(count) earlier steps")
          .foregroundStyle(isHovering ? .primary : .secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      } expanded: {
        EmptyView()
      }
    }
  }

  private func reveal() {
    let store = disclosureStore ?? .previews
    let change = {
      store.setExpanded(kind.earlierHistoryDisclosureKey(messageID: messageID), true)
      invalidateRowMeasurement?()
    }
    performAnchoredDisclosureChange?(change) ?? change()
  }
}
