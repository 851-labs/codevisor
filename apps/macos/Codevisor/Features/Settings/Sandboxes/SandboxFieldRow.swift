import CodevisorCore
import SwiftUI

struct SandboxFieldRow: View {
  let field: ServerSandboxField
  @Binding var draft: SandboxFieldDraft
  var secretSaved = false
  var hosts: [SandboxHost] = []

  var body: some View {
    switch field.type {
    case .boolean:
      Toggle(isOn: flag) { label }
    case .choice:
      Picker(selection: text) {
        ForEach(field.choices ?? [], id: \.value) { Text($0.label).tag($0.value) }
      } label: {
        label
      }
    case .machine:
      Picker(selection: text) {
        Text("Choose a Mac").tag("")
        ForEach(hosts) { Text($0.name).tag($0.serverId) }
      } label: {
        label
      }
    case .secret:
      SecureField(text: text, prompt: Text(secretSaved ? "Saved; leave blank to keep" : field.placeholder ?? "")) {
        label
      }
    case .string, .url, .number:
      TextField(text: text, prompt: Text(prompt)) { label }
    }
  }

  private var label: some View {
    VStack(alignment: .leading) {
      Text(field.required ? field.label : "\(field.label) (optional)")
      if let help = helpText {
        Text(help)
      }
    }
  }

  private var helpText: String? {
    if field.type == .machine, hosts.isEmpty { return "None of your connected Macs can run this" }
    return field.help
  }

  private var prompt: String {
    field.placeholder ?? field.defaultValue?.text ?? ""
  }

  private var text: Binding<String> {
    Binding(get: { draft.text[field.key] ?? "" }, set: { draft.text[field.key] = $0 })
  }

  private var flag: Binding<Bool> {
    Binding(get: { draft.flags[field.key] ?? false }, set: { draft.flags[field.key] = $0 })
  }
}
