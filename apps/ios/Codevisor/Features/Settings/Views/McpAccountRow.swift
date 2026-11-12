import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpAccountRow: View {
  let account: McpAccountState
  let actions: McpAccountActions
  let isWorking: Bool
  let onSignIn: () -> Void
  let onSignOut: () -> Void

  var body: some View {
    switch account {
    case .signedIn:
      Text(actions.accountTitle)
        .swipeActions {
          Button(actions.signOutTitle, role: .destructive, action: onSignOut)
        }
        .contextMenu {
          Button(actions.signInAgainTitle, systemImage: "pencil", action: onSignIn)
          Button(actions.signOutTitle, systemImage: "trash", role: .destructive, action: onSignOut)
        }
    case .signedOut:
      Button(actions.signInTitle, action: onSignIn)
        .fontWeight(.semibold)
        .disabled(isWorking)
    case .settling(let status):
      Text(status).foregroundStyle(.secondary)
    }
  }
}
