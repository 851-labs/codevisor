import CodevisorUI
import SwiftUI

struct SettingsAccountsSection<Rows: View, Buttons: View>: View {
  var title = "Accounts"
  let isSignedOut: Bool
  var signedOutText = "Not signed in"
  let message: String?
  @ViewBuilder let rows: () -> Rows
  @ViewBuilder let buttons: () -> Buttons

  var body: some View {
    Section {
      if isSignedOut {
        Text(signedOutText).foregroundStyle(.secondary)
      }
      rows()
    } header: {
      Text(title)
    } footer: {
      SettingsListActions(message: message, actions: buttons)
    }
  }
}
