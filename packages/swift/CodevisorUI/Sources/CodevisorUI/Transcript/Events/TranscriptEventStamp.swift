import CodevisorCore
import SwiftUI

struct TranscriptEventStamp: View {
  let marker: TranscriptEventMarker
  let summary: TranscriptEventSummary

  var body: some View {
    TranscriptEventPopoverButton(marker: marker) { isPresented in
      TranscriptEventStampLabel(summary: summary, isActive: isPresented)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }
}

struct TranscriptEventStampLabel: View {
  let summary: TranscriptEventSummary
  let isActive: Bool

  var body: some View {
    TranscriptEventTitle(
      summary: summary, iconSize: summary.namesPartyLast ? 14 : 12, iconSpacing: 4, nameStyle: .secondary,
      titleStyle: .tertiary
    )
    .font(.caption2.weight(.medium))
    .foregroundStyle(summary.tone.style(standard: .tertiary))
    .opacity(isActive ? 0.7 : 1)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary.sentence)
  }
}
