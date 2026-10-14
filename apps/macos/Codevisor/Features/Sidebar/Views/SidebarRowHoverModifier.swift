import CodevisorTheming
import CodevisorUI
import SwiftUI

struct SidebarRowHoverModifier: ViewModifier {
  var isSelected = false
  var isEnabled = true
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  func body(content: Content) -> some View {
    let showsHover = controlActiveState == .key && isEnabled && isHovered
    content
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            isSelected
              ? theme.rowSelectedBackground
              : (showsHover ? theme.rowHoverBackground : .clear))
      )
      .onHover { isHovered = $0 }
  }
}

extension View {
  func sidebarRowHover(isSelected: Bool = false, isEnabled: Bool = true) -> some View {
    modifier(SidebarRowHoverModifier(isSelected: isSelected, isEnabled: isEnabled))
  }
}
