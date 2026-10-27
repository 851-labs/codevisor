import CodevisorCore
import SwiftUI

struct SandboxAccountPicker: View {
  let provider: ServerSandboxProviderInfo
  let model: SandboxSettingsModel
  @Binding var accountId: String?

  var body: some View {
    Picker(selection: $accountId) {
      if accountId == nil {
        Text("Choose an account").tag(String?.none)
      }
      ForEach(model.accounts(for: provider.id)) { account in
        Text(model.title(of: account)).tag(Optional(account.id))
      }
    } label: {
      Text("Account")
      if model.accounts(for: provider.id).isEmpty {
        Text("Add a \(provider.displayName) account under Provider Accounts first")
      }
    }
  }
}
