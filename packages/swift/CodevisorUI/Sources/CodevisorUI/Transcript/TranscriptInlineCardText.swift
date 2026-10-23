import SwiftUI

struct TranscriptInlineCardText: View {
  let systemImage: String
  let title: String
  let message: String

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
