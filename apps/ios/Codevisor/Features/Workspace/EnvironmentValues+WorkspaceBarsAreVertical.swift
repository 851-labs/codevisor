import SwiftUI

extension EnvironmentValues {
  @Entry var workspaceBarsAreVertical: Bool = false
}

extension View {
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

#if canImport(SwiftUI, _version: 8.0.85)
  @available(iOS 27.1, *)
  private struct VerticalBarsReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
      content.environment(\.workspaceBarsAreVertical, toolbarVerticalEdge != nil)
    }
  }
#endif
