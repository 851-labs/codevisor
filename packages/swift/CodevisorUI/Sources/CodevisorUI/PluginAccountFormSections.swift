import CodevisorCore
import SwiftUI

public struct PluginAccountFormSections: View {
  @Binding var editing: PluginAccountEditing
  let errorMessage: String?

  public init(editing: Binding<PluginAccountEditing>, errorMessage: String?) {
    _editing = editing
    self.errorMessage = errorMessage
  }

  public var body: some View {
    if editing.namesAccount {
      Section {
        ConfigFieldTextInput(label: "Name", text: $editing.label, prompt: Text("Optional"), isSecure: false)
      }
    }
    Section {
      ConfigFieldForm(draft: $editing.draft)
    } footer: {
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      }
    }
  }
}
