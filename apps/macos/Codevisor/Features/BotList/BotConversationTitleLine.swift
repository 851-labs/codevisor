import CodevisorUI
import SwiftUI

struct BotConversationTitleLine: View {
  let name: String
  var status: SidebarRowStatus? = nil

  var body: some View {
    HStack(spacing: 6) {
      Text(name)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if let status {
        Spacer(minLength: 0)
        SidebarRowStatusLabel(status: status)
      }
    }
  }
}
