import CodevisorTheming
import CodevisorUI
import SwiftUI

/// Row chrome (hover highlight + selected background) with ROW-LOCAL hover
/// state, exposed to the content so rows can reveal hover-only controls.
/// Hover must not live on the sidebar itself: a single shared "which id is
/// hovered" string re-evaluated the entire sidebar body — re-sorting every
/// project and session — on every pointer enter/leave.
struct HoverableRow<Content: View>: View {
  var isSelected = false
  var isHoverEnabled = true
  var isHoverForced = false
  @ViewBuilder var content: (_ isHovered: Bool) -> Content
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.theme) private var theme
  @State private var isHovered = false

  var body: some View {
    // An inactive window consumes the first click only to become key. Keep
    // the row visually inert until it can actually respond to the click.
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
