import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment
  let model: PluginAccountsModel
  @State private var editing: PluginAccountEditing?
  @State private var pendingRemoval: ServerPluginAccount?

  var body: some View {
    if let spec = model.spec {
      Section("Accounts") {
        ForEach(model.accounts) { account in
          PluginAccountRow(
            account: account,
            fallbackName: spec.label,
            ingress: model.ingress[account.id] ?? [],
            onEdit: { edit(account, spec: spec) },
            onRemove: { pendingRemoval = account }
          )
        }
        Button(spec.addTitle) { add(spec) }
          .disabled(model.isWorking)
        if let errorMessage = model.errorMessage, editing == nil {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .onChange(of: environment.pluginAccountsRevision) { Task { await model.reload() } }
      .sheet(item: $editing) { PluginAccountEditorSheet(editing: $0, model: model) }
      .confirmationDialog(
        "Remove \(pendingRemoval.map { $0.label ?? $0.identity ?? spec.label } ?? "")?",
        isPresented: removalPresented,
        titleVisibility: .visible
      ) {
        Button("Remove Account", role: .destructive) { removePending() }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  private var removalPresented: Binding<Bool> {
    Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
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

  private func removePending() {
    guard let account = pendingRemoval else { return }
    pendingRemoval = nil
    Task { await model.remove(account) }
  }
}
