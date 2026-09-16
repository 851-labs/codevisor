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
    }
    .accessibilityLabel("New chat")
  }
}
