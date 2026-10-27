import CodevisorCore
import SwiftUI

struct ConfigFieldRow: View {
  let field: ServerConfigField
  @Binding var value: ServerConfigFieldValue?
  let keepsSavedSecret: Bool

  private static let savedSecretPlaceholder = "••••••••"

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
      if let help = field.help {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var control: some View {
    switch field.type {
    case .boolean:
      Toggle(field.label, isOn: flag)
    case .choice:
      ConfigFieldChoicePicker(field: field, value: $value)
    case .secret:
      ConfigFieldTextInput(label: field.label, text: text, prompt: prompt, isSecure: true)
    case .number:
      ConfigFieldTextInput(label: field.label, text: number, prompt: prompt, isSecure: false)
    case .string, .url, .machine:
      ConfigFieldTextInput(label: field.label, text: text, prompt: prompt, isSecure: false)
    }
  }

  private var prompt: Text? {
    if keepsSavedSecret { return Text(Self.savedSecretPlaceholder) }
    return field.placeholder.map { Text($0) }
  }

  private var text: Binding<String> {
    Binding(
      get: { value?.text ?? "" },
      set: { value = $0.isEmpty ? nil : .string($0) }
    )
  }

  private var number: Binding<String> {
    Binding(
      get: { value?.text ?? "" },
      set: { value = Self.numberValue($0) }
    )
  }

  private var flag: Binding<Bool> {
    Binding(
      get: { value?.isTrue ?? false },
      set: { value = .bool($0) }
    )
  }

  private static func numberValue(_ text: String) -> ServerConfigFieldValue? {
    guard !text.isEmpty else { return nil }
    guard let number = Double(text) else { return .string(text) }
    return .number(number)
  }
}
