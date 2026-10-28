import CodevisorCore
import SwiftUI

struct SandboxEditProviderPage: View {
  let provider: ServerSandboxProvider
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var draft: SandboxProviderDraft
  @State private var status: String?

  init(
    provider: ServerSandboxProvider,
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    navigate: @escaping (SandboxSettingsNavigation) -> Void
  ) {
    self.provider = provider
    self.vendor = vendor
    self.model = model
    self.client = client
    self.navigate = navigate
    _draft = State(initialValue: SandboxProviderDraft(vendor: vendor, provider: provider))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "Edit Provider", actionTitle: "Save", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: save
    ) {
      SandboxProviderFields(draft: $draft, vendor: vendor, model: model)
    }
    .onAppear { model.errorMessage = nil }
  }

  private func save() {
    status = "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved != nil { navigate(.pop) }
    }
  }
}
