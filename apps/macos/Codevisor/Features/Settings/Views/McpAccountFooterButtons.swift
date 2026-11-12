import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpAccountFooterButtons: View {
  let account: McpAccountState
  let actions: McpAccountActions
  let isWorking: Bool
  let onSignIn: () -> Void
  let onSignOut: () -> Void

  var body: some View {
    switch account {
    case .signedOut:
      Button(actions.signInTitle, action: onSignIn)
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
    case .signedIn:
      Button("\(actions.signOutTitle)…", action: onSignOut)
        .disabled(isWorking)
    case .settling:
      EmptyView()
    }
  }
}
