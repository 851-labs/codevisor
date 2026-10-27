import CodevisorCore
import SwiftUI

struct SandboxProfileEditor: View {
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
    NavigationStack {
      Form {
        Section {
          LabeledContent("Name") {
            TextField("macOS 27 Tart VM", text: $draft.name)
              .multilineTextAlignment(.trailing)
          }
          if draft.provider.usesAccounts {
            Picker("Account", selection: $draft.accountId) {
              if draft.accountId == nil {
                Text("Choose an account").tag(String?.none)
              }
              ForEach(model.accounts(for: draft.provider.id)) { account in
                Text(model.title(of: account)).tag(Optional(account.id))
              }
            }
          }
          ForEach(draft.provider.profileFields) { field in
            SandboxFieldInput(field: field, draft: $draft.fields, hosts: model.hosts(for: field.capability))
          }
        } footer: {
          SandboxEditorFooter(provider: draft.provider, error: model.errorMessage)
        }
      }
      .navigationTitle(draft.isNew ? "New \(draft.provider.displayName) Profile" : "Edit Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.isNew ? "Create" : "Save", action: save)
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
