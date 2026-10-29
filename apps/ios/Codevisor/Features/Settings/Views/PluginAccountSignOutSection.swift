import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountSignOutSection: View {
  let model: PluginAccountsModel
  @State private var removalCandidates: [ServerPluginAccount] = []

  var body: some View {
    if let spec = model.spec, !model.accounts.isEmpty {
      let actions = PluginAccountActions(spec: spec, accounts: model.accounts)
      Section {
        Button(actions.removeTitle) { removalCandidates = model.accounts }
          .disabled(model.isWorking)
      }
      .pluginAccountRemovalDialog(actions: actions, candidates: $removalCandidates) { account in
        removalCandidates = []
        Task { await model.remove(account) }
      }
    }
  }
}
