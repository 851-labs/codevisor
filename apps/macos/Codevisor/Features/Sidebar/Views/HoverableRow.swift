import CodevisorUI
import SwiftUI

struct HoverableRow<Content: View>: View {
  var isSelected = false
  var isHoverEnabled = true
  var isHoverForced = false
  @ViewBuilder var content: (_ isHovered: Bool) -> Content
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var isHovered = false

  var body: some View {
    let revealsHoverContent = controlActiveState == .key && isHoverEnabled && isHovered
    let showsHoverBackground = isHoverForced || revealsHoverContent
    content(revealsHoverContent)
      .background(
        RoundedRectangle.sidebarRow
          .fill(RowSelectionStyle.fill(isSelected: isSelected, isHovered: showsHoverBackground))
      )
      .onHover { isHovered = $0 }
  }
}
