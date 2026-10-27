import CodevisorCore
import SwiftUI

struct SandboxAccountFields: View {
  @Binding var draft: SandboxAccountDraft
  var namesAccount = false

  var body: some View {
    Section {
      if namesAccount {
        SandboxTextInput(label: "Name", prompt: "Optional", text: $draft.label)
      }
      ForEach(draft.provider.accountFields) { field in
        SandboxFieldRow(field: field, draft: $draft.fields, secretSaved: draft.secretsSet.contains(field.key))
      }
    }
  }
}
