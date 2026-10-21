import SwiftUI

struct NoticeCardText: View {
  let title: String
  let detail: String
  let systemImage: String
  let accent: Color

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
