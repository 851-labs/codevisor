import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRowSubtitle: View {
  let subtitle: String?
  let status: SidebarRowStatus?

  var body: some View {
    HStack(spacing: 5) {
      if let status {
        SidebarRowStatusLabel(status: status)
      }
      if let subtitle {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}
