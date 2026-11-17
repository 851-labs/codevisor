import CodevisorUI
import SwiftUI

struct McpSignOutDialog: ViewModifier {
  let actions: McpAccountActions
  @Binding var isPresented: Bool
  let signOut: () -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(actions.signOutPrompt, isPresented: $isPresented, titleVisibility: .visible) {
      Button(actions.signOutTitle, role: .destructive, action: signOut)
      Button("Cancel", role: .cancel) {}
    }
  }
}
