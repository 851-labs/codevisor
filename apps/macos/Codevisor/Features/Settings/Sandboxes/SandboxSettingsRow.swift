import SwiftUI

struct SandboxSettingsRow: View {
  let systemImage: String
  let title: String
  let subtitle: String
  let isUntested: Bool
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
          if isUntested {
            SandboxUntestedBadge()
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Edit…", action: onEdit)
      Menu {
        Button("Delete…", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More")
    }
    .contextMenu {
      Button("Edit…", action: onEdit)
      Button("Delete…", role: .destructive, action: onDelete)
    }
  }
}
