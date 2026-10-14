import SwiftUI

extension View {
  func pointerHighlight(_ shape: some Shape) -> some View {
    contentShape(.hoverEffect, shape)
      .hoverEffect(.highlight)
  }
}
