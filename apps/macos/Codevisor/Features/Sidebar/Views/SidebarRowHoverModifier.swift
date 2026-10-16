import CodevisorUI
import SwiftUI

struct SidebarRowHoverModifier: ViewModifier {
  var isSelected = false
  var isEnabled = true
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isHovered = false

  func body(content: Content) -> some View {
    let showsHover = controlActiveState == .key && isEnabled && isHovered
    content
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            isSelected
              ? Color.primary.opacity(0.14)
              : (showsHover ? Color.secondary.opacity(0.12) : .clear))
      )
      .onHover { isHovered = $0 }
  }
}

extension View {
  func sidebarRowHover(isSelected: Bool = false, isEnabled: Bool = true) -> some View {
    modifier(SidebarRowHoverModifier(isSelected: isSelected, isEnabled: isEnabled))
  }
}
