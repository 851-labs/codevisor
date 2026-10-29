import CodevisorCore
import SwiftUI

struct SandboxFieldRow: View {
  let field: ServerSandboxField
  @Binding var draft: SandboxFieldDraft
  var secretSaved = false
  var hosts: [SandboxHost] = []
  var steps: SandboxFieldSteps?
  var onCommit: (() -> Void)?

  var body: some View {
    switch field.type {
    case .boolean:
      Toggle(field.label, isOn: flag)
        .onChange(of: flag.wrappedValue) { onCommit?() }
    case .choice:
      Picker(field.label, selection: text) {
        ForEach(field.choices ?? [], id: \.value) { Text($0.label).tag($0.value) }
      }
      .onChange(of: text.wrappedValue) { onCommit?() }
    case .machine:
      machinePicker
        .onChange(of: text.wrappedValue) { onCommit?() }
    case .secret:
      SandboxTextInput(label: field.label, prompt: secretPrompt, text: text, isSecret: true, onCommit: onCommit)
    case .number:
      numberInput
    case .url:
      SandboxTextInput(label: field.label, prompt: prompt, text: text, keyboard: .url, onCommit: onCommit)
    case .string:
      SandboxTextInput(label: field.label, prompt: prompt, text: text, onCommit: onCommit)
    }
  }

  @ViewBuilder
  private var numberInput: some View {
    if let steps {
      SandboxStepPicker(field: field, steps: steps, text: text)
        .onChange(of: text.wrappedValue) { onCommit?() }
    } else {
      SandboxTextInput(label: field.label, prompt: prompt, text: text, keyboard: .number, onCommit: onCommit)
    }
  }

  private var machinePicker: some View {
    Picker(selection: text) {
      Text("Choose a Mac").tag("")
      ForEach(hosts) { Text($0.name).tag($0.serverId) }
    } label: {
      Text(field.label)
      if hosts.isEmpty {
        Text("None of your connected Macs can run this")
      }
    }
  }

  private var prompt: String { field.placeholder ?? field.defaultValue?.text ?? "" }

  private var secretPrompt: String { secretSaved ? "Saved" : field.placeholder ?? "" }

  private var text: Binding<String> {
    Binding(get: { draft.text[field.key] ?? "" }, set: { draft.text[field.key] = $0 })
  }

  private var flag: Binding<Bool> {
    Binding(get: { draft.flags[field.key] ?? false }, set: { draft.flags[field.key] = $0 })
  }
}
