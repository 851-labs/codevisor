import CodevisorCore
import SwiftUI

struct SandboxNewProviderPage: View {
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var draft: SandboxProviderDraft
  @State private var status: String?

  init(
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    navigate: @escaping (SandboxSettingsNavigation) -> Void
  ) {
    self.vendor = vendor
    self.model = model
    self.client = client
    self.navigate = navigate
    _draft = State(initialValue: SandboxProviderDraft(vendor: vendor))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "Set Up \(vendor.displayName)", actionTitle: "Add Provider", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: add
    ) {
      SandboxProviderFields(draft: $draft, vendor: vendor, model: model)
    }
    .onAppear { model.errorMessage = nil }
  }

  private func add() {
    status = "Adding…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if let saved { navigate(.reset(to: .newProfile(providerId: saved.id))) }
    }
  }
}
