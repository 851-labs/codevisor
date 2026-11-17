import SwiftUI

extension View {
  public func anchoredPopover(
    isPresented: Binding<Bool>, arrowEdge: Edge, @ViewBuilder content: @escaping () -> some View
  ) -> some View {
    popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
      .background { PopoverAnchorScrollDismissal(isPresented: isPresented) }
  }
}

private struct PopoverAnchorScrollDismissal: View {
  @Binding var isPresented: Bool

  var body: some View {
    #if os(macOS)
      if isPresented {
        PopoverAnchorTracker { isPresented = false }
      }
    #endif
  }
}
