import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let model: PluginAccountsModel
  @State private var editing: PluginAccountEditing?
  @State private var removalCandidates: [ServerPluginAccount] = []

  var body: some View {
    if let spec = model.spec {
      let actions = PluginAccountActions(spec: spec, accounts: model.accounts)
      Section {
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
        accountButtons(actions)
      } header: {
        Text("Accounts")
      } footer: {
        if let errorMessage = model.errorMessage, editing == nil {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .onChange(of: environment?.pluginAccountsRevision) { Task { await model.reload() } }
      .sheet(item: $editing) { PluginAccountEditorScreen(editing: $0, model: model) }
      .pluginAccountRemovalDialog(actions: actions, candidates: $removalCandidates) { remove($0) }
    }
  }

  @ViewBuilder
  private func accountButtons(_ actions: PluginAccountActions) -> some View {
    if actions.needsFirstAccount {
      Button(actions.spec.addTitle) { add(actions.spec) }
        .fontWeight(.semibold)
        .disabled(model.isWorking)
    } else {
      if let account = actions.revisitTarget {
        Button(actions.revisitTitle(for: account)) { edit(account, spec: actions.spec) }
          .disabled(model.isWorking)
      }
      Button(actions.addAnotherTitle) { add(actions.spec) }
        .disabled(model.isWorking)
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

  private func remove(_ account: ServerPluginAccount) {
    removalCandidates = []
    Task { await model.remove(account) }
  }
}
