import CodevisorCore
import SwiftUI

struct SandboxAccountsSection: View {
  let model: SandboxSettingsModel
  let onAdd: (ServerSandboxProviderInfo) -> Void
  let onEdit: (ServerSandboxAccount) -> Void
  let onDelete: (ServerSandboxAccount) -> Void

  var body: some View {
    Section {
      if model.accounts.isEmpty, model.hasLoaded {
        Text("No provider accounts yet")
          .foregroundStyle(.secondary)
      }
      ForEach(model.accounts) { account in
        SandboxSettingsRow(
          systemImage: "person.crop.circle",
          title: model.title(of: account),
          subtitle: subtitle(for: account),
          isUntested: model.provider(account.provider)?.tested == false,
          onEdit: { onEdit(account) },
          onDelete: { onDelete(account) }
        )
      }
    } header: {
      HStack {
        Text("Provider Accounts")
        Spacer()
        SandboxProviderMenu(title: "Add Account", providers: model.accountProviders, onPick: onAdd)
      }
    } footer: {
      Text("Sign in to a provider once to use it on all your machines. Tart needs no account.")
        .foregroundStyle(.secondary)
    }
  }

  private func subtitle(for account: ServerSandboxAccount) -> String {
    let used = model.profiles.filter { $0.accountId == account.id }.map(\.name)
    return used.isEmpty ? "Not used by any profile" : "Used by \(used.formatted(.list(type: .and)))"
  }
}
