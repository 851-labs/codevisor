import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRowSubtitle: View {
  let subtitle: String?
  let status: SidebarRowStatus?

  var body: some View {
    SidebarRowStatusSubtitle(status: status, subtitle: subtitle) { text in
      Text(text)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}
