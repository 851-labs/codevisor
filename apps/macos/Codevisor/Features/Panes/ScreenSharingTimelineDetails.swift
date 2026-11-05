import ScreenSharing
import SwiftUI

struct ScreenSharingTimelineDetails: View {
  let timeline: ScreenSharingTimelineBreakdown

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text("Frame timeline")
          Text("p50").gridColumnAlignment(.trailing)
          Text("p95").gridColumnAlignment(.trailing)
        }
        .fontWeight(.semibold)
        ForEach(timeline.stages) { ScreenSharingTimelineRow(row: $0) }
        if let total = timeline.total { ScreenSharingTimelineRow(row: total).fontWeight(.semibold) }
      }
      Text(timeline.caption).font(.caption).foregroundStyle(.secondary)
    }
    .monospacedDigit()
  }
}

private struct ScreenSharingTimelineRow: View {
  let row: ScreenSharingTimelineBreakdown.Row

  var body: some View {
    GridRow {
      Text(row.label)
      Text(row.p50)
      Text(row.p95)
    }
  }
}
