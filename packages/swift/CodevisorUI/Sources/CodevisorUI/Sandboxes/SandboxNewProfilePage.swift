import CodevisorCore
import SwiftUI

struct SandboxNewProfilePage: View {
  let provider: ServerSandboxProvider
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var draft: SandboxProfileDraft
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
    _draft = State(initialValue: SandboxProfileDraft(provider: provider, vendor: vendor))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "New Profile", actionTitle: "Add Profile", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: add
    ) {
      Section {
        LabeledContent("Provider", value: model.title(of: provider))
      }
      SandboxProfileFields(draft: $draft, vendor: vendor, model: model)
    }
    .onAppear { model.errorMessage = nil }
  }

  private func add() {
    status = "Adding…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { navigate(.reset(to: nil)) }
    }
  }
}
