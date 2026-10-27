import SwiftUI

struct SandboxListRow: View {
  let systemImage: String
  let title: String
  let subtitle: String
  let isUntested: Bool

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
            .foregroundStyle(.primary)
          if isUntested {
            Text("Untested")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.orange.opacity(0.15), in: .capsule)
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
    }
  }
}
