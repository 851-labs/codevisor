import SwiftUI

struct TranscriptBottomEdgeExtent: ViewModifier {
  let tracksKeyboardInset: Bool
  let chatBottomSafeArea: CGFloat
  let isKeyboardUp: Bool

  func body(content: Content) -> some View {
    if tracksKeyboardInset {
      content
        .padding(.bottom, isKeyboardUp ? -chatBottomSafeArea : 0)
        .clipped()
        .padding(.bottom, isKeyboardUp ? 0 : -chatBottomSafeArea)
        .ignoresSafeArea(.container, edges: .top)
    } else {
      content
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
  }
}
