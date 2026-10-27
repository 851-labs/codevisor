import CodevisorCore
import SwiftUI

struct SandboxAccountsList: View {
  let model: SandboxSettingsModel
  let onAdd: (ServerSandboxProviderInfo) -> Void
  let onEdit: (ServerSandboxAccount) -> Void
  let onDelete: (ServerSandboxAccount) -> Void

  var body: some View {
    Section {
      ForEach(model.accounts) { account in
        Button {
          onEdit(account)
        } label: {
          SandboxListRow(
            systemImage: "person.crop.circle",
            title: model.title(of: account),
            subtitle: usage(of: account),
            isUntested: model.provider(account.provider)?.tested == false
          )
        }
        .buttonStyle(.plain)
        .swipeActions {
          Button("Remove", role: .destructive) { onDelete(account) }
        }
      }
      SandboxAddMenu(title: "Add Account", providers: model.accountProviders, onPick: onAdd)
    } header: {
      Text("Provider Accounts")
    } footer: {
      Text("Sign in to a provider once to use it on all your machines. Tart needs no account.")
    }
  }

  private func usage(of account: ServerSandboxAccount) -> String {
    let used = model.profiles.filter { $0.accountId == account.id }.map(\.name)
    return used.isEmpty ? "Not used by any profile" : "Used by \(used.formatted(.list(type: .and)))"
  }
}
