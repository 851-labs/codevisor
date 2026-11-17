import CodevisorCore
import SwiftUI

struct SandboxChoicePicker: View {
  let field: ServerSandboxField
  @Binding var selection: String

  var body: some View {
    Picker(field.label, selection: $selection) {
      ForEach(field.choices ?? [], id: \.value) { Text($0.label).tag($0.value) }
    }
    .onChange(of: field.choices, initial: true) { fit() }
  }

  private func fit() {
    guard let choices = field.choices, !selection.isEmpty, !choices.contains(where: { $0.value == selection }),
      let largest = choices.last(where: { Double($0.value) != nil })
    else { return }

    selection = largest.value
  }
}
