import SwiftUI

struct EdgeToEdgePaneHost<Content: View>: View {
  @ViewBuilder let content: (_ size: CGSize, _ safeArea: EdgeInsets) -> Content

  var body: some View {
    GeometryReader { safe in
      let insets = EdgeInsets(top: safe.safeAreaInsets.top, leading: 0, bottom: safe.safeAreaInsets.bottom, trailing: 0)
      GeometryReader { proxy in
        content(proxy.size, insets)
      }
      .ignoresSafeArea(edges: .vertical)
    }
  }
}
