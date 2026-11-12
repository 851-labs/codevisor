import CodevisorUI
import SwiftUI

struct SettingsAccountsSection<Rows: View, Buttons: View>: View {
  let isSignedOut: Bool
  let message: String?
  @ViewBuilder let rows: () -> Rows
  @ViewBuilder let buttons: () -> Buttons

  var body: some View {
    Section {
      if isSignedOut {
        Text("Not signed in").foregroundStyle(.secondary)
      }
      rows()
    } header: {
      Text("Accounts")
    } footer: {
      SettingsListActions(message: message, actions: buttons)
    }
  }
}
