import CodevisorUI
import SwiftUI

struct SidebarRowHoverModifier: ViewModifier {
  var isSelected = false
  var isEnabled = true
  var cornerRadius: CGFloat = 6
  var cornerStyle: RoundedCornerStyle = .circular
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isHovered = false

  func body(content: Content) -> some View {
    let showsHover = controlActiveState == .key && isEnabled && isHovered
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
          .fill(
            isSelected
              ? Color.primary.opacity(0.14)
              : (showsHover ? Color.secondary.opacity(0.12) : .clear))
      )
      .onHover { isHovered = $0 }
  }
}

extension View {
  func sidebarRowHover(
    isSelected: Bool = false, isEnabled: Bool = true, cornerRadius: CGFloat = 6,
    cornerStyle: RoundedCornerStyle = .circular
  ) -> some View {
    modifier(
      SidebarRowHoverModifier(
        isSelected: isSelected, isEnabled: isEnabled, cornerRadius: cornerRadius, cornerStyle: cornerStyle))
  }
}
