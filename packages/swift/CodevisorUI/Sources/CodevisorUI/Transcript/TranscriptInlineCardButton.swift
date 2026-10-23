import SwiftUI

struct TranscriptInlineCardButton: View {
  let action: TranscriptInlineCard.Action

  var body: some View {
    if action.emphasis == .primary {
      label.buttonStyle(.borderedProminent)
    } else {
      label.buttonStyle(.bordered).tint(.primary)
    }
  }

  private var label: some View {
    Button(action: action.perform) {
      Text(action.title)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
    .controlSize(TranscriptInlineCardMetrics.controlSize)
  }
}
