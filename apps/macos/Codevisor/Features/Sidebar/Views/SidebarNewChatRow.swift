import SwiftUI

struct SidebarNewChatRow: View {
  @SidebarSelectionRef var selection: SidebarSelection?
  let isHoverEnabled: Bool

  var body: some View {
    SidebarActionRow(
      title: "New chat",
      systemImage: "square.and.pencil",
      isSelected: selection.showsNewChat,
      isHoverEnabled: isHoverEnabled
    ) {
      selection = .newChat(nil)
    }
  }
}
