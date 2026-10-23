import SwiftUI

struct TranscriptInlineCardText: View {
  let title: String
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
