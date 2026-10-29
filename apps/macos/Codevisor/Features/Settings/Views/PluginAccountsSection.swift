import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment
  let model: PluginAccountsModel
  @State private var editing: PluginAccountEditing?
  @State private var removalCandidates: [ServerPluginAccount] = []

  var body: some View {
    if let spec = model.spec {
      let actions = PluginAccountActions(spec: spec, accounts: model.accounts)
      Section {
        if actions.needsFirstAccount {
          Text("Not signed in").foregroundStyle(.secondary)
        }
        ForEach(model.accounts) { account in
          PluginAccountRow(
            account: account,
            fallbackName: spec.label,
            ingress: model.ingress[account.id] ?? [],
            actions: actions,
            onEdit: { edit(account, spec: spec) },
            onRemove: { removalCandidates = [account] }
          )
        }
      } header: {
        Text("Accounts")
      } footer: {
        SettingsListActions(message: editing == nil ? model.errorMessage : nil) {
          PluginAccountFooterButtons(
            actions: actions,
            isWorking: model.isWorking,
            onAdd: { add(spec) },
            onEdit: { edit($0, spec: spec) },
            onRemove: { removalCandidates = model.accounts }
          )
        }
      }
      .onChange(of: environment.pluginAccountsRevision) { Task { await model.reload() } }
      .sheet(item: $editing) { PluginAccountEditorSheet(editing: $0, model: model) }
      .confirmationDialog(
        actions.removalPrompt(for: removalCandidates),
        isPresented: removalPresented,
        titleVisibility: .visible
      ) {
        ForEach(removalCandidates) { account in
          Button(actions.removalButtonTitle(for: account, among: removalCandidates), role: .destructive) {
            remove(account)
          }
        }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  private var removalPresented: Binding<Bool> {
    Binding(get: { !removalCandidates.isEmpty }, set: { if !$0 { removalCandidates = [] } })
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

  private func remove(_ account: ServerPluginAccount) {
    removalCandidates = []
    Task { await model.remove(account) }
  }
}
