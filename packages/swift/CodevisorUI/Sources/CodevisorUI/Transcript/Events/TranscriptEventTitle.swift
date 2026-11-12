import SwiftUI

struct TranscriptEventTitle: View {
  private static let maxNameWidth: CGFloat = 180

  let summary: TranscriptEventSummary
  let nameStyle: HierarchicalShapeStyle
  let titleStyle: HierarchicalShapeStyle

  var body: some View {
    HStack(spacing: 3) {
      if let name = summary.agentName {
        CappedWidthLayout(maxWidth: Self.maxNameWidth) {
          Text(name)
            .lineLimit(1)
        }
        .foregroundStyle(summary.tone.style(standard: nameStyle))
        .help(name)
      }
      Text(summary.title)
        .lineLimit(1)
        .layoutPriority(1)
        .foregroundStyle(summary.tone.style(standard: titleStyle))
    }
  }
}
