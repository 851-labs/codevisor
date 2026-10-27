import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var editing: PluginAccountEditing
  let model: PluginAccountsModel

  init(editing: PluginAccountEditing, model: PluginAccountsModel) {
    _editing = State(initialValue: editing)
    self.model = model
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(editing.title)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
      Form {
        PluginAccountFormSections(editing: $editing, errorMessage: model.errorMessage)
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(editing.submitTitle) { Task { await submit() } }
          .keyboardShortcut(.defaultAction)
          .disabled(!editing.canSubmit || model.isWorking)
      }
      .padding()
    }
    .frame(width: 440)
    .frame(minHeight: 240)
  }

  private func submit() async {
    guard await model.submit(editing), model.errorMessage == nil else { return }
    dismiss()
  }
}
