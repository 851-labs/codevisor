import SwiftUI

struct CommandPaletteItemLabel: View {
  let title: String
  let subtitle: String?

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .lineLimit(1)
        .layoutPriority(1)
      if let subtitle {
        Text(subtitle)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}
