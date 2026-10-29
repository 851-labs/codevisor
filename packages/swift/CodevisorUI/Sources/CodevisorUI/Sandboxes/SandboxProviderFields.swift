import CodevisorCore
import SwiftUI

struct SandboxProviderFields<Footer: View>: View {
  @Binding var draft: SandboxProviderDraft
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  @ViewBuilder let footer: () -> Footer

  init(
    draft: Binding<SandboxProviderDraft>,
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    @ViewBuilder footer: @escaping () -> Footer
  ) {
    _draft = draft
    self.vendor = vendor
    self.model = model
    self.footer = footer
  }

  init(draft: Binding<SandboxProviderDraft>, vendor: ServerSandboxVendor, model: SandboxSettingsModel)
  where Footer == EmptyView {
    self.init(draft: draft, vendor: vendor, model: model) { EmptyView() }
  }

  var body: some View {
    Section {
      ForEach(draft.shownFields) { field in
        SandboxFieldRow(
          field: field, draft: $draft.fields, secretSaved: draft.secretsSet.contains(field.key),
          hosts: model.hosts(for: field.capability))
      }
    } footer: {
      footer()
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
