import SwiftUI

struct TranscriptEventTitle: View {
  private static let maxNameWidth: CGFloat = 180

  private static let nameSpacing: CGFloat = 3

  let summary: TranscriptEventSummary
  let iconSize: CGFloat
  let iconSpacing: CGFloat
  let nameStyle: HierarchicalShapeStyle
  let titleStyle: HierarchicalShapeStyle

  var body: some View {
    HStack(spacing: iconSpacing) {
      if summary.namesPartyLast {
        title
        HStack(spacing: Self.nameSpacing) {
          icon
          name
        }
      } else {
        icon
        HStack(spacing: Self.nameSpacing) {
          name
          title
        }
      }
    }
  }

  private var icon: some View {
    TranscriptEventIcon(icon: summary.icon, size: iconSize)
  }

  @ViewBuilder private var name: some View {
    if let name = summary.agentName {
      CappedWidthLayout(maxWidth: Self.maxNameWidth) {
        Text(name)
          .lineLimit(1)
      }
      .foregroundStyle(summary.tone.style(standard: nameStyle))
      .help(name)
    }
  }

  private var title: some View {
    Text(summary.title)
      .lineLimit(1)
      .layoutPriority(1)
      .foregroundStyle(summary.tone.style(standard: titleStyle))
  }
}
