import CodevisorCore
import SwiftUI

struct SandboxEditProviderPage: View {
  let provider: ServerSandboxProvider
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let onDone: () -> Void
  @State private var draft: SandboxProviderDraft
  @State private var status: String?
  @State private var deleting: ServerSandboxProvider?

  init(
    provider: ServerSandboxProvider,
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    onDone: @escaping () -> Void
  ) {
    self.provider = provider
    self.vendor = vendor
    self.model = model
    self.client = client
    self.onDone = onDone
    _draft = State(initialValue: SandboxProviderDraft(vendor: vendor, provider: provider))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "Edit Provider", actionTitle: "Save", canAct: draft.canSave, status: status,
      errorMessage: model.error(outside: draft.shownFields.map(\.key)), onAction: save, onDelete: delete
    ) {
      SandboxProviderFields(draft: $draft, vendor: vendor, model: model)
      SandboxDeleteSection(title: "Delete Provider", onDelete: delete)
    }
    .modifier(
      SandboxProviderDeletion(provider: $deleting, model: model, client: client, status: $status, onDeleted: onDone)
    )
    .onAppear { model.errorMessage = nil }
  }

  private func save() {
    status = "Saving…"
    Task {
      let outcome = await model.save(draft, using: client)
      status = nil
      switch outcome {
      case .saved: onDone()
      case let .choose(field): draft.offer(field)
      case .failed: break
      }
    }
  }

  private func delete() {
    deleting = provider
  }
}
