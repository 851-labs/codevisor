import CodevisorCore
import SwiftUI

struct SandboxStepPicker: View {
  let field: ServerSandboxField
  let steps: SandboxFieldSteps
  @Binding var text: String

  var body: some View {
    Picker(field.label, selection: $text) {
      ForEach(steps.values, id: \.self) { value in
        Text(label(for: value)).tag(Self.text(for: value))
      }
    }
    .pickerStyle(.menu)
    .onChange(of: steps, initial: true) { fit() }
  }

  private func fit() {
    let fitted = Self.text(for: steps.fitted(Double(text)))
    guard fitted != text else { return }

    text = fitted
  }

  private func label(for value: Double) -> String {
    let number = Self.text(for: value)
    guard let unit = field.unit else { return number }
    return "\(number) \(unit)"
  }

  private static func text(for value: Double) -> String {
    SandboxFieldValue.number(value).text
  }
}
