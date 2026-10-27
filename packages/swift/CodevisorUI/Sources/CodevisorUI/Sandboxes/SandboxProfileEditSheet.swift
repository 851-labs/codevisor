import CodevisorCore
import SwiftUI

public struct SandboxProfileEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxProfileDraft
  @State private var status: String?
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
        title: "Edit Profile", confirmTitle: "Save", canConfirm: draft.canSave, status: status,
        onCancel: { dismiss() }, onConfirm: save
      ) {
        Form {
          SandboxSheetError(message: model.errorMessage)
          SandboxProfileFields(draft: $draft, model: model, choosesAccount: choosesAccount)
        }
        .formStyle(.grouped)
      }
    }
    #if os(macOS)
      .sheetSize(.step)
    #endif
    .interactiveDismissDisabled(status != nil)
    .onAppear { model.errorMessage = nil }
  }

  private var choosesAccount: Bool { model.accounts(for: draft.provider.id).count > 1 }

  private func save() {
    status = "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { dismiss() }
    }
  }
}
