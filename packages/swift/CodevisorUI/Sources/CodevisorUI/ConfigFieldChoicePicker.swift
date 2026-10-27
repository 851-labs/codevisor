import CodevisorCore
import SwiftUI

struct ConfigFieldChoicePicker: View {
  let field: ServerConfigField
  @Binding var value: ServerConfigFieldValue?

  var body: some View {
    Picker(field.label, selection: selection) {
      if !field.required {
        Text("None").tag("")
      }
      ForEach(field.choices ?? []) { choice in
        Text(choice.label).tag(choice.value)
      }
    }
  }

  private var selection: Binding<String> {
    Binding(
      get: { value?.text ?? "" },
      set: { value = $0.isEmpty ? nil : .string($0) }
    )
  }
}
