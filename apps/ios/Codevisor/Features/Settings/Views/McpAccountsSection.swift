import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: McpFleetEntry
  let model: McpGlobalModel
  @State private var confirmingSignOut = false
  @State private var isWorking = false

  var body: some View {
    if let account {
      Section("Accounts") {
        McpAccountRow(
          account: account, actions: actions, isWorking: isWorking,
          onSignIn: signIn, onSignOut: { confirmingSignOut = true })
      }
      if account == .signedIn {
        Section {
          Button(actions.signOutTitle) { confirmingSignOut = true }
            .disabled(isWorking)
        }
        .confirmationDialog(actions.signOutPrompt, isPresented: $confirmingSignOut, titleVisibility: .visible) {
          Button(actions.signOutTitle, role: .destructive, action: signOut)
          Button("Cancel", role: .cancel) {}
        }
      }
    }
  }

  private var account: McpAccountState? {
    McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment)).account
  }

  private var actions: McpAccountActions { McpAccountActions(serverName: entry.name) }

  private func signIn() {
    perform { await model.signIn(entry, in: environment) }
  }

  private func signOut() {
    perform { await model.disconnect(entry, in: environment) }
  }

  private func perform(_ operation: @escaping () async -> Void) {
    isWorking = true
    Task {
      await operation()
      isWorking = false
    }
  }
}
