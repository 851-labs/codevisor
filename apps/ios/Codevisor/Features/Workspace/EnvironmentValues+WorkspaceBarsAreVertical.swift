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
    #if canImport(SwiftUI, _version: 8.0.85)
      if #available(iOS 27.1, *) {
        modifier(VerticalBarsReader())
      } else {
        self
      }
    #else
      self
    #endif
  }
}

// iOS 27.1 SDK APIs (the fold-aware toolbar edge and arrangement view).
// Release CI builds with the iOS 27.0 SDK, where they don't exist; an
// `#available` check alone still has to compile against them.
#if canImport(SwiftUI, _version: 8.0.85)
  @available(iOS 27.1, *)
  private struct VerticalBarsReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
      content.environment(\.workspaceBarsAreVertical, toolbarVerticalEdge != nil)
    }
  }
#endif
