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
      HStack(spacing: 10) {
        Text(actions.accountTitle)
        Spacer()
        Button("\(actions.signOutTitle)…", action: onSignOut)
          .disabled(isWorking)
      }
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
