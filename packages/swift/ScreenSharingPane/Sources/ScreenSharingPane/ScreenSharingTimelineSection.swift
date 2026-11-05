#if os(iOS)
  import ScreenSharing
  import SwiftUI

  struct ScreenSharingTimelineSection: View {
    let timeline: ScreenSharingTimelineBreakdown

    var body: some View {
      Section {
        ForEach(timeline.stages) { LabeledContent($0.label, value: $0.value) }
        if let total = timeline.total { LabeledContent(total.label, value: total.value).fontWeight(.semibold) }
      } header: {
        Text("Frame timeline · p50 / p95")
      } footer: {
        Text(timeline.caption)
      }
      .monospacedDigit()
    }
  }
#endif
