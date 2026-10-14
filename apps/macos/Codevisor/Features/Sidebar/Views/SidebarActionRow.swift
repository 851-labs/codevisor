import SwiftUI

struct SidebarActionRow: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let isHoverEnabled: Bool
  var titleStyle: HierarchicalShapeStyle = .primary
  let action: () -> Void

  var body: some View {
    SidebarHeaderRow(title: title, systemImage: systemImage, titleStyle: titleStyle)
      .contentShape(Rectangle())
      .sidebarRowHover(isSelected: isSelected, isEnabled: isHoverEnabled)
      .onTapGesture(perform: action)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction(.default, action)
  }
}
