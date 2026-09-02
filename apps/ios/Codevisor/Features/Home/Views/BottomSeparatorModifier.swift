import SwiftUI

/// Only the final visible row overrides SwiftUI's native separator behavior.
/// Keeping the visible case structurally unmodified is important during a
/// native move: an explicit row trait can otherwise travel with the reused
/// cell that used to be last.
struct BottomSeparatorModifier: ViewModifier {
  let isHidden: Bool?

  @ViewBuilder
  func body(content: Content) -> some View {
    if isHidden == true {
      content.listRowSeparator(.hidden, edges: .bottom)
    } else {
      content
    }
  }
}
