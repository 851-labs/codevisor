import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment
  let model: PluginAccountsModel
  @State private var editing: PluginAccountEditing?
  @State private var guiding: PluginAccountGuideModel?
  @State private var removing: ServerPluginAccount?

  var body: some View {
    if let spec = model.spec {
      let actions = PluginAccountActions(spec: spec, accounts: model.accounts)
      SettingsAccountsSection(
        title: spec.accountsTitle,
        isSignedOut: actions.needsFirstAccount,
        signedOutText: spec.guide?.summary ?? "Not signed in",
        message: editing == nil ? model.errorMessage : nil
      ) {
        ForEach(model.accounts) { account in
          PluginAccountRow(
            account: account,
            fallbackName: spec.label,
            ingress: model.ingress[account.id] ?? [],
            actions: actions,
            isWorking: model.isWorking,
            onEdit: { edit(account, spec: spec) },
            onRemove: { removing = account }
          )
        }
      } buttons: {
        PluginAccountFooterButtons(actions: actions, isWorking: model.isWorking) { add(spec) }
      }
      .onChange(of: environment.pluginAccountsRevision) { Task { await model.reload() } }
      .sheet(item: $editing) { PluginAccountEditorSheet(editing: $0, model: model) }
      .sheet(item: $guiding) { PluginAccountGuideSetupSheet(model: $0) { await model.reload() } }
      .task(id: model.hasLoaded) { offerFirstRunGuide() }
      .confirmationDialog(
        removing.map(actions.removalPrompt(for:)) ?? "",
        isPresented: removalPresented,
        titleVisibility: .visible,
        presenting: removing
      ) { account in
        Button(actions.removeTitle, role: .destructive) { remove(account) }
        Button("Cancel", role: .cancel) {}
      }
    }
  }

  private var removalPresented: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private func edit(_ account: ServerPluginAccount, spec: ServerPluginAccountSpec) {
    guard account.isOAuth, spec.signsInDirectly else {
      editing = PluginAccountEditing(account: account, spec: spec)
      return
    }
    Task { await model.signIn(accountId: account.id) }
  }

  private func offerFirstRunGuide() {
    guard guiding == nil else { return }
    guiding = model.takeFirstRunGuide()
  }

  private func add(_ spec: ServerPluginAccountSpec) {
    if let guide = model.makeGuide() {
      guiding = guide
      return
    }
    guard spec.signsInDirectly else {
      editing = PluginAccountEditing(newAccountFor: spec)
      return
    }
    Task { await model.signIn() }
  }

  private func remove(_ account: ServerPluginAccount) {
    removing = nil
    Task { await model.remove(account) }
  }
}
