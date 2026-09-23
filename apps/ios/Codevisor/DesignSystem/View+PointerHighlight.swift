import SwiftUI

extension View {
  /// The pointer's hover highlight drawn in the control's visible shape.
  /// Without the shape it follows the content shape, which for our icon
  /// buttons is the enlarged square touch target around a small circle.
  func pointerHighlight(_ shape: some Shape) -> some View {
    contentShape(.hoverEffect, shape)
      .hoverEffect(.highlight)
  }
}
