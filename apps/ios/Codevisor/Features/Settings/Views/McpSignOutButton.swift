import CodevisorUI
import SwiftUI

struct McpSignOutButton: View {
  let actions: McpAccountActions
  let isWorking: Bool
  let signOut: () -> Void
  @State private var confirmsSignOut = false

  var body: some View {
    Button(actions.signOutTitle) { confirmsSignOut = true }
      .disabled(isWorking)
      .modifier(McpSignOutDialog(actions: actions, isPresented: $confirmsSignOut, signOut: signOut))
  }
}
