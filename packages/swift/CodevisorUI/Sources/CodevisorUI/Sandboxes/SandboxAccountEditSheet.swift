import CodevisorCore
import SwiftUI

public struct SandboxAccountEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxAccountDraft
  @State private var status: String?
  private let model: SandboxSettingsModel
  private let client: any CodevisorServerClienting

  public init(draft: SandboxAccountDraft, model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    _draft = State(initialValue: draft)
    self.model = model
    self.client = client
  }

  public var body: some View {
    NavigationStack {
      SandboxSheetPage(
        title: "Edit Account", confirmTitle: "Save", canConfirm: draft.canSave, status: status,
        onCancel: { dismiss() }, onConfirm: save
      ) {
        Form {
          SandboxSheetError(message: model.errorMessage)
          SandboxAccountFields(draft: $draft, namesAccount: true)
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

  private func save() {
    status = "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { dismiss() }
    }
  }
}
