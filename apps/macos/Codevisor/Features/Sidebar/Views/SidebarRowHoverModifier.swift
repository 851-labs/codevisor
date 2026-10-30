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
        RoundedRectangle.sidebarRow
          .fill(RowSelectionStyle.fill(isSelected: isSelected, isHovered: showsHover))
      )
      .contentShape(.focusEffect, RoundedRectangle.sidebarRow)
      .sidebarHover($isHovered)
  }
}

extension View {
  func sidebarRowHover(isSelected: Bool = false, isEnabled: Bool = true) -> some View {
    modifier(SidebarRowHoverModifier(isSelected: isSelected, isEnabled: isEnabled))
  }
}

extension RoundedRectangle {
  static let sidebarRow = RowSelectionStyle.shape
}
