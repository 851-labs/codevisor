import SwiftUI

/// Lays the workspace's pane out edge to edge — under the top bar, down to
/// the screen's bottom, and never shrunk by the keyboard — and hands it the
/// safe area it would otherwise have had, so the pane handles its own:
/// scrolling content runs under the bar, while controls clear the home
/// indicator and rise above the keyboard.
///
/// Only the vertical edges extend. The leading safe area is the sidebar
/// floating over the detail column, which the pane should sit beside, not
/// under.
///
/// A reader that ignores the safe area reports no insets, so an outer
/// reader that respects it measures them first.
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
