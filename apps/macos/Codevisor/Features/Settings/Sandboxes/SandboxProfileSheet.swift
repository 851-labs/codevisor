import CodevisorCore
import SwiftUI

struct SandboxProfileSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxProfileDraft
  @State private var isSaving = false
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting

  init(draft: SandboxProfileDraft, model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    _draft = State(initialValue: draft)
    self.model = model
    self.client = client
  }

  var body: some View {
    Form {
      Section {
        SandboxProviderHeader(provider: draft.provider, title: draft.isNew ? "New Profile" : "Edit Profile")
      }
      Section {
        TextField(text: $draft.name, prompt: Text("macOS 27 Tart VM")) {
          Text("Name")
          Text("Shown in the machine picker as “New \(draft.name)”")
        }
        if draft.provider.usesAccounts {
          SandboxAccountPicker(provider: draft.provider, model: model, accountId: $draft.accountId)
        }
        ForEach(draft.provider.profileFields) { field in
          SandboxFieldRow(field: field, draft: $draft.fields, hosts: model.hosts(for: field.capability))
        }
      } footer: {
        SandboxSheetError(message: model.errorMessage)
      }
    }
    .formStyle(.grouped)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(draft.isNew ? "Create" : "Save", action: save)
          .disabled(!draft.canSave || isSaving)
      }
    }
    .frame(width: 520)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    .onAppear { model.errorMessage = nil }
  }

  private func save() {
    isSaving = true
    Task {
      let saved = await model.save(draft, using: client)
      isSaving = false
      if saved { dismiss() }
    }
  }
}
