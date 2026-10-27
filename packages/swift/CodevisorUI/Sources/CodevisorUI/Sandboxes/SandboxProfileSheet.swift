import CodevisorCore
import SwiftUI

public struct SandboxProfileSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxProfileDraft
  @State private var status: String?
  @State private var isAddingProvider = false
  @State private var editingProvider: SandboxProviderDraft?
  private let model: SandboxSettingsModel
  private let client: any CodevisorServerClienting

  public init(draft: SandboxProfileDraft, model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    _draft = State(initialValue: draft)
    self.model = model
    self.client = client
  }

  public var body: some View {
    NavigationStack {
      SandboxSheetPage(
        title: draft.isNew ? "Add Profile" : "Edit Profile", confirmTitle: draft.isNew ? "Add Profile" : "Save",
        canConfirm: draft.canSave, status: status, onCancel: { dismiss() }, onConfirm: save
      ) {
        Form {
          SandboxSheetError(message: model.errorMessage)
          Section {
            SandboxProviderSelect(
              model: model, selection: selectedProviderId, onSelect: choose,
              onAdd: { isAddingProvider = true }, onEdit: edit)
          }
          if let vendor = draft.vendor, selectedProviderId != nil {
            SandboxProfileFields(draft: $draft, vendor: vendor, model: model)
          }
        }
        .formStyle(.grouped)
      }
    }
    #if os(macOS)
      .sheetSize(.list)
    #endif
    .interactiveDismissDisabled(status != nil)
    .onAppear { model.errorMessage = nil }
    .sheet(isPresented: $isAddingProvider) {
      SandboxProviderSheet(draft: SandboxProviderDraft(), model: model, client: client, onSaved: choose)
    }
    .sheet(item: $editingProvider) { provider in
      SandboxProviderSheet(draft: provider, model: model, client: client, onSaved: { _ in })
    }
  }

  private var selectedProviderId: String? {
    model.provider(draft.providerId)?.id
  }

  private func choose(_ provider: ServerSandboxProvider) {
    guard let vendor = model.vendor(provider.vendor) else { return }
    draft.choose(provider, vendor: vendor)
  }

  private func edit(_ provider: ServerSandboxProvider) {
    editingProvider = SandboxProviderDraft(vendor: model.vendor(provider.vendor), provider: provider)
  }

  private func save() {
    status = "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { dismiss() }
    }
  }
}
