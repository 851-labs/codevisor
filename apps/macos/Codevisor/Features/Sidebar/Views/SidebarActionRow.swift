import SwiftUI

/// A pinned sidebar action ("New chat"): the shared header-row label with
/// selection and hover chrome, and a tap action.
struct SidebarActionRow: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let isHoverEnabled: Bool
  let action: () -> Void

  var body: some View {
    SidebarHeaderRow(title: title, systemImage: systemImage)
      .contentShape(Rectangle())
      .sidebarRowHover(isSelected: isSelected, isEnabled: isHoverEnabled)
      .onTapGesture(perform: action)
  }
}
