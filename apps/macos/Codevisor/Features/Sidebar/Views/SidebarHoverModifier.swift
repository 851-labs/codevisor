import CodevisorUI
import SwiftUI

struct SidebarHoverModifier: ViewModifier {
  @Binding var isHovered: Bool
  @Environment(\.isActiveSidebarMode) private var isActiveSidebarMode
  @Environment(\.sidebarRevealCount) private var revealCount

  func body(content: Content) -> some View {
    content
      .onHover { isHovered = $0 }
      .onChange(of: isActiveSidebarMode) { isHovered = false }
      .onChange(of: revealCount) { isHovered = false }
  }
}

extension View {
  func sidebarHover(_ isHovered: Binding<Bool>) -> some View {
    modifier(SidebarHoverModifier(isHovered: isHovered))
  }
}
