import SwiftUI

struct TranscriptInlineCardText: View {
  let title: String
  let message: String
  var tone: TranscriptInlineCard.Tone = .neutral

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleLabel
        .font(.callout.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var titleLabel: some View {
    switch tone {
    case .neutral:
      Text(title).foregroundStyle(.primary)
    case .error:
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        Text(title).foregroundStyle(.primary)
      }
    }
  }
}
