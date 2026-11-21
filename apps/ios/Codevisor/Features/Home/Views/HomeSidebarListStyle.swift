import SwiftUI

struct HomeSidebarListStyle: ViewModifier {
  static let outlineTopOffset: CGFloat = -13

  let isConversation: Bool

  func body(content: Content) -> some View {
    if isConversation {
      content.listStyle(.plain)
    } else {
      content.listStyle(.sidebar)
        .environment(\.defaultMinListHeaderHeight, 0)
        .contentMargins(.top, Self.outlineTopOffset, for: .scrollContent)
    }
  }
}
