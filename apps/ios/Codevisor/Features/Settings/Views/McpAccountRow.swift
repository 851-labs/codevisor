import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpAccountRow: View {
  let account: McpAccountState
  let actions: McpAccountActions
  let isWorking: Bool
  let onSignIn: () -> Void
  let onSignOut: () -> Void
  @State private var confirmsSignOut = false

  var body: some View {
    switch account {
    case .signedIn:
      Text(actions.accountTitle)
        .swipeActions {
          ConfirmingDestructiveButton(actions.signOutTitle) { confirmsSignOut = true }
        }
        .contextMenu {
          Button(actions.signInAgainTitle, systemImage: "pencil", action: onSignIn)
          Button(actions.signOutTitle, systemImage: "trash", role: .destructive) { confirmsSignOut = true }
        }
        .modifier(McpSignOutDialog(actions: actions, isPresented: $confirmsSignOut, signOut: onSignOut))
    case .signedOut:
      Button(actions.signInTitle, action: onSignIn)
        .fontWeight(.semibold)
        .disabled(isWorking)
    case .settling(let status):
      Text(status).foregroundStyle(.secondary)
    }
  }
}
