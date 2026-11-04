import SwiftUI

struct HomeSidebarListStyle: ViewModifier {
  let isConversation: Bool

  func body(content: Content) -> some View {
    if isConversation {
      content.listStyle(.plain)
    } else {
      content.listStyle(.sidebar)
    }
  }
}
