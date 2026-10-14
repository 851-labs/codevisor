import SwiftUI

struct VerticalBarEdgeReader: View {
  let onChange: (Bool) -> Void

  var body: some View {
    #if canImport(SwiftUI, _version: 8.0.85)
      if #available(iOS 27.1, *) {
        Color.clear.modifier(VerticalBarEdgeProbe(onChange: onChange))
      } else {
        Color.clear
      }
    #else
      Color.clear
    #endif
  }
}

#if canImport(SwiftUI, _version: 8.0.85)
  @available(iOS 27.1, *)
  private struct VerticalBarEdgeProbe: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
      content.onChange(of: toolbarVerticalEdge != nil, initial: true) { _, isVertical in
        onChange(isVertical)
      }
    }
  }
#endif
