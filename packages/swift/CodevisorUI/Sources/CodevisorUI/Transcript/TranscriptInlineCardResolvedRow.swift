import SwiftUI

struct TranscriptInlineCardResolvedRow: View {
  let title: String
  let outcome: TranscriptInlineCard.Outcome

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      TranscriptInlineCardStatusIcon(outcome: outcome)
    }
  }
}
