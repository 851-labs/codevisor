import SwiftUI

struct SidebarDropHighlight: View {
  let isActive: Bool

  var body: some View {
    RoundedRectangle.sidebarRow.fill(RowSelectionStyle.fill(isSelected: false, isHovered: isActive))
  }
}
