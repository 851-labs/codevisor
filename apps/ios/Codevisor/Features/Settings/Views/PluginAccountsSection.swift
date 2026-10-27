import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let model: PluginAccountsModel
  @State private var editing: PluginAccountEditing?

  var body: some View {
    if let spec = model.spec {
      Section {
        ForEach(model.accounts) { account in
          PluginAccountRow(
            account: account,
            fallbackName: spec.label,
            ingress: model.ingress[account.id] ?? [],
            onEdit: { edit(account, spec: spec) },
            onRemove: { Task { await model.remove(account) } }
          )
        }
        Button(spec.addTitle) { add(spec) }
          .disabled(model.isWorking)
      } header: {
        Text("Accounts")
      } footer: {
        if let errorMessage = model.errorMessage, editing == nil {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .onChange(of: environment?.pluginAccountsRevision) { Task { await model.reload() } }
      .sheet(item: $editing) { PluginAccountEditorScreen(editing: $0, model: model) }
    }
  }

  private func edit(_ account: ServerPluginAccount, spec: ServerPluginAccountSpec) {
    guard account.isOAuth, spec.signsInDirectly else {
      editing = PluginAccountEditing(account: account, spec: spec)
      return
    }
    Task { await model.signIn(accountId: account.id) }
  }

  private func add(_ spec: ServerPluginAccountSpec) {
    guard spec.signsInDirectly else {
      editing = PluginAccountEditing(newAccountFor: spec)
      return
    }
    Task { await model.signIn() }
  }
}
