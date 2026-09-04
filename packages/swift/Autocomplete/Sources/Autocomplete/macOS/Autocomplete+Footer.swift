#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// The pinned region under the list — "Manage Harnesses…", "Add
    /// Scheme…" — separated by a divider. Put ordinary `Item`s in it: they
    /// filter, highlight, accept, and render icons, shortcuts, checkmarks,
    /// and accessories exactly like the rows above, and the popup's last
    /// row takes the concentric bottom corners on its own.
    struct Footer<Content: View>: View {
      let content: Content

      @Environment(\.autocompleteStyle) private var style

      public init(@ViewBuilder content: () -> Content) {
        self.content = content()
      }

      public var body: some View {
        let metrics = style.metrics
        VStack(spacing: 0) {
          SwiftUI.Divider()
          VStack(alignment: .leading, spacing: 0) {
            content
          }
          .padding(.horizontal, metrics.footerHorizontalInset)
          .padding(.vertical, metrics.footerVerticalInset)
        }
      }
    }
  }
#endif
