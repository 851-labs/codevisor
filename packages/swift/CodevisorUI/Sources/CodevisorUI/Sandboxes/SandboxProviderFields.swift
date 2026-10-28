import CodevisorCore
import SwiftUI

struct SandboxProviderFields: View {
  @Binding var draft: SandboxProviderDraft
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel

  var body: some View {
    Section {
      ForEach(draft.shownFields) { field in
        SandboxFieldRow(
          field: field, draft: $draft.fields, secretSaved: draft.secretsSet.contains(field.key),
          hosts: model.hosts(for: field.capability))
      }
    }
    .onAppear(perform: chooseOnlyMac)
    .onChange(of: vendor.id) { _, _ in chooseOnlyMac() }
  }

  private func chooseOnlyMac() {
    for field in vendor.providerFields where field.type == .machine {
      let hosts = model.hosts(for: field.capability)
      guard hosts.count == 1, draft.fields.text[field.key, default: ""].isEmpty else { continue }
      draft.fields.text[field.key] = hosts[0].serverId
    }
  }
}
