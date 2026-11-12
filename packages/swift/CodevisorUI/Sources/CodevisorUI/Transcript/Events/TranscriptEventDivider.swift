import CodevisorCore
import SwiftUI

struct TranscriptEventDivider: View {
  let marker: TranscriptEventMarker
  let summary: TranscriptEventSummary

  var body: some View {
    HStack(spacing: 10) {
      TranscriptEventRule()
      TranscriptEventPopoverButton(marker: marker) { isPresented in
        TranscriptEventDividerLabel(summary: summary, isActive: isPresented)
      }
      .layoutPriority(1)
      TranscriptEventRule()
    }
    .frame(maxWidth: .infinity)
  }
}

private struct TranscriptEventDividerLabel: View {
  let summary: TranscriptEventSummary
  let isActive: Bool

  var body: some View {
    HStack(spacing: 6) {
      TranscriptEventIcon(icon: summary.icon, size: 14)
      Text(summary.title)
        .lineLimit(1)
    }
    .font(.caption)
    .foregroundStyle(summary.tone.style(standard: .secondary))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(Color.primary.opacity(isActive ? 0.1 : 0)))
    .contentShape(Capsule())
    .accessibilityElement(children: .combine)
  }
}

private struct TranscriptEventRule: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.1))
      .frame(height: 1)
  }
}
