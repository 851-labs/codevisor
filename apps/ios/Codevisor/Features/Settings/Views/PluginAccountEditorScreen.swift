import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountEditorScreen: View {
  @Environment(\.dismiss) private var dismiss
  @State private var editing: PluginAccountEditing
  let model: PluginAccountsModel

  init(editing: PluginAccountEditing, model: PluginAccountsModel) {
    _editing = State(initialValue: editing)
    self.model = model
  }

  var body: some View {
    NavigationStack {
      Form {
        PluginAccountFormSections(editing: $editing, errorMessage: model.errorMessage)
      }
      .navigationTitle(editing.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(editing.submitTitle) { Task { await submit() } }
            .disabled(!editing.canSubmit || model.isWorking)
        }
      }
    }
  }

  private func submit() async {
    guard await model.submit(editing), model.errorMessage == nil else { return }
    dismiss()
  }
}
