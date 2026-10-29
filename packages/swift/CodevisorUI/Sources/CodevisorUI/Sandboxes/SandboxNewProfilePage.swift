import CodevisorCore
import SwiftUI

struct SandboxNewProfilePage: View {
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  @Binding var providerId: String
  let onNewProvider: () -> Void
  let onAdded: () -> Void
  @State private var draft: SandboxProfileDraft
  @State private var status: String?

  init(
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    provider: ServerSandboxProvider,
    vendor: ServerSandboxVendor,
    providerId: Binding<String>,
    onNewProvider: @escaping () -> Void,
    onAdded: @escaping () -> Void
  ) {
    self.model = model
    self.client = client
    _providerId = providerId
    self.onNewProvider = onNewProvider
    self.onAdded = onAdded
    _draft = State(initialValue: SandboxProfileDraft(provider: provider, vendor: vendor))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "New Profile", actionTitle: "Add Profile", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: add
    ) {
      Section {
        SandboxProviderPicker(model: model, providerId: $providerId, onNewProvider: onNewProvider)
      }
      if let vendor = draft.vendor {
        SandboxProfileFields(draft: $draft, vendor: vendor, model: model)
      }
    }
    .onAppear { model.errorMessage = nil }
    .onChange(of: providerId) { chooseProvider() }
  }

  private func chooseProvider() {
    guard let provider = model.provider(providerId), let vendor = model.vendor(provider.vendor) else { return }

    draft.choose(provider, vendor: vendor)
  }

  private func add() {
    status = "Adding…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { onAdded() }
    }
  }
}
