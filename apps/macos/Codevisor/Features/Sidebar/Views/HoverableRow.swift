import CodevisorTheming
import CodevisorUI
import SwiftUI

struct HoverableRow<Content: View>: View {
  var isSelected = false
  var isHoverEnabled = true
  var isHoverForced = false
  @ViewBuilder var content: (_ isHovered: Bool) -> Content
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  var body: some View {
    let revealsHoverContent = controlActiveState == .key && isHoverEnabled && isHovered
    let showsHoverBackground = isHoverForced || revealsHoverContent
    content(revealsHoverContent)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            isSelected
              ? theme.rowSelectedBackground
              : (showsHoverBackground ? theme.rowHoverBackground : .clear))
      )
      .onHover { isHovered = $0 }
  }
}
