import SwiftUI

struct SidebarRowPressModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content.onLongPressGesture(minimumDuration: 0, perform: action)
  }
}

extension View {
  func onSidebarRowPress(perform action: @escaping () -> Void) -> some View {
    modifier(SidebarRowPressModifier(action: action))
  }
}
