import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Toolbar

extension HomeView {
  var newChatButton: some View {
    Button {
      presentNewChat()
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 18, weight: .semibold))
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .matchedTransitionSource(
      id: Self.newChatTransitionID,
      in: newChatTransition
    )
    .padding(.trailing, 16)
    .padding(.bottom, 8)
    .accessibilityLabel("New chat")
  }
}
