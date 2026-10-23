import SwiftUI

struct TranscriptInlineCardStatusIcon: View {
  let outcome: TranscriptInlineCard.Outcome

  var body: some View {
    switch outcome {
    case let .completed(label):
      Image(systemName: "checkmark.circle.fill")
        .imageScale(.large)
        .foregroundStyle(.green)
        .accessibilityLabel(label)
    case let .declined(label):
      Image(systemName: "circle")
        .imageScale(.large)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }
  }
}
