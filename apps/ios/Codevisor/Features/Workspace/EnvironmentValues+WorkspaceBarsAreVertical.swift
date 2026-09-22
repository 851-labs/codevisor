import SwiftUI

/// Whether the hosting navigation bar has moved its items into iPhone Duo's
/// vertical strip. Chrome that animates against the top bar's geometry (the
/// New Chat sheet's back-button morph) skips itself when it has.
extension EnvironmentValues {
  @Entry var workspaceBarsAreVertical: Bool = false
}

extension View {
  /// Publishes `workspaceBarsAreVertical` from the system's toolbar edge on
  /// iOS 27.1; earlier systems never place bars vertically.
  @ViewBuilder
  func detectsVerticalBars() -> some View {
    if #available(iOS 27.1, *) {
      modifier(VerticalBarsReader())
    } else {
      self
    }
  }
}

@available(iOS 27.1, *)
private struct VerticalBarsReader: ViewModifier {
  @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

  func body(content: Content) -> some View {
    content.environment(\.workspaceBarsAreVertical, toolbarVerticalEdge != nil)
  }
}
