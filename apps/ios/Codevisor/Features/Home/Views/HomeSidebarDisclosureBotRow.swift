import SwiftUI

struct HomeSidebarDisclosureBotRow: View {
  let row: HomeSidebarBotRowView
  @Binding var isExpanded: Bool
  let isConversation: Bool

  var body: some View {
    HStack(spacing: 8) {
      row.equatable()
      Button {
        isExpanded.toggle()
      } label: {
        HomeSidebarDisclosureChevron(isExpanded: isExpanded, style: isConversation ? .conversation : .system)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }
  }
}
