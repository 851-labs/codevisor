import SwiftUI

/// Reports whether the hosting navigation container has moved its bar items
/// into iPhone Duo's vertical strip. Placed inside the container's content
/// so it reads that container's own bar, not an ancestor's.
struct VerticalBarEdgeReader: View {
  let onChange: (Bool) -> Void

  var body: some View {
    if #available(iOS 27.1, *) {
      Color.clear.modifier(VerticalBarEdgeProbe(onChange: onChange))
    } else {
      // Earlier systems never lay a bar out vertically.
      Color.clear
    }
  }
}

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
