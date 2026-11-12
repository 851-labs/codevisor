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

private struct TranscriptEventStampLabel: View {
  let summary: TranscriptEventSummary
  let isActive: Bool

  var body: some View {
    HStack(spacing: 4) {
      TranscriptEventIcon(icon: summary.icon, size: 12)
      Text(summary.title)
        .lineLimit(1)
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(summary.tone.style(standard: .tertiary))
    .opacity(isActive ? 0.7 : 1)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
