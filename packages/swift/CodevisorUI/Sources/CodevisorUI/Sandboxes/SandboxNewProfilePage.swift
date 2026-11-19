import CodevisorCore
import SwiftUI

struct SandboxNewProfilePage: View {
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let provider: ServerSandboxProvider
  let vendor: ServerSandboxVendor
  let onAdded: () -> Void
  @State private var draft: SandboxProfileDraft
  @State private var status: String?

  init(
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    provider: ServerSandboxProvider,
    vendor: ServerSandboxVendor,
    onAdded: @escaping () -> Void
  ) {
    self.model = model
    self.client = client
    self.provider = provider
    self.vendor = vendor
    self.onAdded = onAdded
    _draft = State(initialValue: SandboxProfileDraft(provider: provider, vendor: vendor))
  }

  var body: some View {
    SandboxSettingsForm(
      title: title, actionTitle: "Add Profile", canAct: draft.canSave,
      status: status, errorMessage: model.error(outside: draft.fieldKeys), onAction: add
    ) {
      SandboxProfileFields(draft: $draft, vendor: vendor, model: model)
    }
    .onAppear { model.errorMessage = nil }
    .task { await model.loadMaximums(of: provider.id, from: client) }
  }

  private var title: String {
    #if os(macOS)
      "New \(vendor.displayName) Profile"
    #else
      "New Profile"
    #endif
  }

  private func add() {
    status = "Adding…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      guard saved else { return await model.loadMaximums(of: provider.id, from: client) }

      onAdded()
    }
  }
}
