import SwiftUI

struct TranscriptInlineCardResolvedRow: View {
  let systemImage: String
  let title: String
  let outcome: TranscriptInlineCard.Outcome

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      TranscriptInlineCardStatusIcon(outcome: outcome)
    }
  }
}
