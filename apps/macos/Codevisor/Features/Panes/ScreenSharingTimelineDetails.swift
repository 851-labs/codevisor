import ScreenSharing
import SwiftUI

struct ScreenSharingTimelineDetails: View {
  let timeline: ScreenSharingTimelineBreakdown

  private static let spacing: CGFloat = 6

  var body: some View {
    VStack(alignment: .leading, spacing: Self.spacing) {
      Text("Frame timeline · p50 / p95")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, WorkspaceInspectorCardShape.rowPadding)
      ScreenSharingDetailsCard {
        ForEach(timeline.stages) { LabeledContent($0.label, value: $0.value) }
        if let total = timeline.total { LabeledContent(total.label, value: total.value).fontWeight(.semibold) }
      }
      Text(timeline.caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, WorkspaceInspectorCardShape.rowPadding)
    }
  }
}
