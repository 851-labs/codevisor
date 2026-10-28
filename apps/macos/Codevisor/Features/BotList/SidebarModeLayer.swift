import SwiftUI

struct SidebarModeLayer: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
  }
}
