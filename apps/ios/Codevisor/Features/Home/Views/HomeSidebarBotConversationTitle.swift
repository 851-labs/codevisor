import CodevisorUI
import SwiftUI

struct HomeSidebarBotConversationTitle: View {
  let name: String
  var status: SidebarRowStatus? = nil
  var showsStatusLabel = false
  let showsChevron: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      HomeSidebarRowTitle(title: name)
        .fontWeight(.semibold)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let status, SidebarBotStatusBadge.isVisible(status, showsLabel: showsStatusLabel) {
        SidebarBotStatusBadge(status: status, showsLabel: showsStatusLabel)
      }
      if showsChevron {
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
  }
}
