import CodevisorUI
import SwiftUI

struct HomeSidebarBotConversationTitle: View {
  let name: String
  var status: SidebarRowStatus? = nil
  let showsChevron: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      HomeSidebarRowTitle(title: name)
        .fontWeight(.semibold)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let status {
        SidebarRowStatusLabel(status: status)
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
