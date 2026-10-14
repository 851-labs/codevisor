import SwiftUI

extension View {
  func popupSurface() -> some View {
    modifier(PopupSurfaceModifier())
  }
}

private struct PopupSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
