import SwiftUI

struct FrozenWhileHidden<Content: View>: View, Equatable {
  let isShown: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    !lhs.isShown && !rhs.isShown
  }
}
