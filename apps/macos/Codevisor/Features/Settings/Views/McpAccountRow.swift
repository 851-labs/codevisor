import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpAccountRow: View {
  let account: McpAccountState
  let actions: McpAccountActions
  let onSignIn: () -> Void
  let onSignOut: () -> Void

  var body: some View {
    switch account {
    case .signedIn:
      Text(actions.accountTitle)
        .contextMenu {
          Button(actions.signInAgainTitle, action: onSignIn)
          Button("\(actions.signOutTitle)…", role: .destructive, action: onSignOut)
        }
    case .settling(let status):
      Text(status).foregroundStyle(.secondary)
    case .signedOut:
      EmptyView()
    }
  }
}
