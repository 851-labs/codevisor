import CodevisorCore
import SwiftUI

struct SandboxAccountSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxAccountDraft
  @State private var isSaving = false
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting

  init(draft: SandboxAccountDraft, model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    _draft = State(initialValue: draft)
    self.model = model
    self.client = client
  }

  var body: some View {
    Form {
      Section {
        SandboxProviderHeader(
          provider: draft.provider, title: draft.isNew ? "Sign in to \(draft.provider.displayName)" : "Edit Account")
      }
      Section {
        TextField("Name (optional)", text: $draft.label, prompt: Text("Work, Personal…"))
        ForEach(draft.provider.accountFields) { field in
          SandboxFieldRow(field: field, draft: $draft.fields, secretSaved: draft.secretsSet.contains(field.key))
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
        Button(draft.isNew ? "Sign In" : "Save", action: save)
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
