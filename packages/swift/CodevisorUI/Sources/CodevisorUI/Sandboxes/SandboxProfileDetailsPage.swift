import CodevisorCore
import SwiftUI

struct SandboxProfileDetailsPage: View {
  let title: String
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let onCancel: () -> Void
  let onCreated: () -> Void
  @State private var draft: SandboxNewProfileDraft
  @State private var status: String?

  init(
    choice: SandboxSetupChoice,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    onCancel: @escaping () -> Void,
    onCreated: @escaping () -> Void
  ) {
    title = model.title(of: choice)
    self.model = model
    self.client = client
    self.onCancel = onCancel
    self.onCreated = onCreated
    _draft = State(initialValue: SandboxNewProfileDraft(choice: choice))
  }

  var body: some View {
    SandboxSheetPage(
      title: title, confirmTitle: "Add Profile", canConfirm: draft.canSave, status: status,
      showsCancel: false, onCancel: onCancel, onConfirm: create
    ) {
      Form {
        SandboxSheetError(message: model.errorMessage)
        if let account = Binding($draft.account) {
          SandboxAccountFields(draft: account)
        }
        SandboxProfileFields(draft: $draft.profile, model: model)
      }
      .formStyle(.grouped)
    }
    .interactiveDismissDisabled(status != nil)
    .onAppear { model.errorMessage = nil }
  }

  private func create() {
    status = draft.account == nil ? "Adding…" : "Signing in…"
    Task {
      let creation = await model.create(draft, using: client)
      status = nil
      switch creation {
      case .created: onCreated()
      case let .failed(remaining): draft = remaining
      }
    }
  }
}
