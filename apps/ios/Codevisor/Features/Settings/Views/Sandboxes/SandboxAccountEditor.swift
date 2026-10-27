import CodevisorCore
import SwiftUI

struct SandboxAccountEditor: View {
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
    NavigationStack {
      Form {
        Section {
          LabeledContent("Name (optional)") {
            TextField("Work, Personal…", text: $draft.label)
              .multilineTextAlignment(.trailing)
          }
          ForEach(draft.provider.accountFields) { field in
            SandboxFieldInput(field: field, draft: $draft.fields, secretSaved: draft.secretsSet.contains(field.key))
          }
        } footer: {
          SandboxEditorFooter(provider: draft.provider, error: model.errorMessage)
        }
      }
      .navigationTitle(draft.isNew ? "Sign in to \(draft.provider.displayName)" : "Edit Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.isNew ? "Sign In" : "Save", action: save)
            .disabled(!draft.canSave || isSaving)
        }
      }
    }
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
