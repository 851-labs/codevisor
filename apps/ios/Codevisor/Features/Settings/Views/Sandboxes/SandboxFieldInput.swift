import CodevisorCore
import SwiftUI

struct SandboxFieldInput: View {
  let field: ServerSandboxField
  @Binding var draft: SandboxFieldDraft
  var secretSaved = false
  var hosts: [SandboxHost] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
      if let help = helpText {
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
      Toggle(title, isOn: flag)
    case .choice:
      Picker(title, selection: text) {
        ForEach(field.choices ?? [], id: \.value) { Text($0.label).tag($0.value) }
      }
    case .machine:
      Picker(title, selection: text) {
        Text("Choose a Mac").tag("")
        ForEach(hosts) { Text($0.name).tag($0.serverId) }
      }
    case .secret:
      LabeledContent(title) {
        SecureField(secretSaved ? "Saved; leave blank to keep" : field.placeholder ?? "", text: text)
          .multilineTextAlignment(.trailing)
      }
    case .number:
      LabeledContent(title) {
        TextField(prompt, text: text)
          .keyboardType(.decimalPad)
          .multilineTextAlignment(.trailing)
      }
    case .string, .url:
      LabeledContent(title) {
        TextField(prompt, text: text)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(field.type == .url ? .URL : .default)
          .multilineTextAlignment(.trailing)
      }
    }
  }

  private var title: String { field.isOptional ? "\(field.label) (optional)" : field.label }

  private var helpText: String? {
    if field.type == .machine, hosts.isEmpty { return "None of your connected Macs can run this" }
    return field.help
  }

  private var prompt: String { field.placeholder ?? field.defaultValue?.text ?? "" }

  private var text: Binding<String> {
    Binding(get: { draft.text[field.key] ?? "" }, set: { draft.text[field.key] = $0 })
  }

  private var flag: Binding<Bool> {
    Binding(get: { draft.flags[field.key] ?? false }, set: { draft.flags[field.key] = $0 })
  }
}
