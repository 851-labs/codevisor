import CodevisorUI
import SwiftUI

struct SidebarHoverModifier: ViewModifier {
  @Binding var isHovered: Bool
  @Environment(\.isActiveSidebarMode) private var isActiveSidebarMode
  @Environment(SidebarHostBridge.self) private var hostBridge: SidebarHostBridge?

  func body(content: Content) -> some View {
    content
      .onHover { isHovered = $0 }
      .onChange(of: isActiveSidebarMode) { isHovered = false }
      .onChange(of: revealWhileHovered) { previous, current in
        if previous != nil, current != nil { isHovered = false }
      }
  }

  private var revealWhileHovered: Int? {
    isHovered ? hostBridge?.revealCount : nil
  }
}

extension View {
  func sidebarHover(_ isHovered: Binding<Bool>) -> some View {
    modifier(SidebarHoverModifier(isHovered: isHovered))
  }
}
