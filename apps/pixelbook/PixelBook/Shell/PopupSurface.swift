import SwiftUI

extension View {
  /// The chrome a popover would give a popup rendered directly on the
  /// canvas: Liquid Glass. Its corner radius is `Metrics.bottomCornerRadius`
  /// plus the list's vertical inset, so the last row's highlight sits
  /// concentric with the container.
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
