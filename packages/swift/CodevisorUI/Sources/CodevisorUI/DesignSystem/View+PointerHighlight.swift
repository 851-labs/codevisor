import SwiftUI

#if os(iOS)
  extension View {
    public func pointerHighlight(_ shape: some Shape) -> some View {
      contentShape(.hoverEffect, shape)
        .hoverEffect(.highlight)
    }
  }
#endif
