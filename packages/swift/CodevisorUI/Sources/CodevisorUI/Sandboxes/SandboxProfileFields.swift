import CodevisorCore
import SwiftUI

struct SandboxProfileFields: View {
  @Binding var draft: SandboxProfileDraft
  let model: SandboxSettingsModel
  var choosesAccount = false

  var body: some View {
    Section {
      SandboxTextInput(label: "Name", prompt: "", text: $draft.name)
      if choosesAccount {
        Picker("Account", selection: $draft.accountId) {
          ForEach(model.accounts(for: draft.provider.id)) { account in
            Text(model.title(of: account)).tag(Optional(account.id))
          }
        }
      }
      ForEach(draft.provider.profileFields) { field in
        SandboxFieldRow(field: field, draft: $draft.fields, hosts: model.hosts(for: field.capability))
      }
    }
    .onAppear(perform: chooseOnlyHost)
  }

  private func chooseOnlyHost() {
    for field in draft.provider.profileFields where field.type == .machine {
      let hosts = model.hosts(for: field.capability)
      guard hosts.count == 1, draft.fields.text[field.key, default: ""].isEmpty else { continue }
      draft.fields.text[field.key] = hosts[0].serverId
    }
  }
}
