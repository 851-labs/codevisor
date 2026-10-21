import SwiftUI

struct ComposerModeLabel: View {
  let systemImage: String
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.caption)
      Text(title)
        .font(.caption.weight(.semibold))
    }
    .foregroundStyle(.secondary)
  }
}
