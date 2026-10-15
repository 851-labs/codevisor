import CodevisorCore
import CodevisorUI
import SwiftUI

struct EditMachineSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  @State private var name: String
  @State private var icon: String
  let isLocal: Bool
  let onSave: (_ name: String, _ icon: String) -> Void
  let onDisconnect: (() -> Void)?

  init(
    machine: CloudMachine,
    isLocal: Bool,
    onSave: @escaping (_ name: String, _ icon: String) -> Void,
    onDisconnect: (() -> Void)?
  ) {
    self.isLocal = isLocal
    self.onSave = onSave
    self.onDisconnect = onDisconnect
    _name = State(initialValue: machine.name)
    _icon = State(initialValue: MachineIcon.systemImage(for: machine.icon))
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Form {
      Section {
        header
      }
      .listRowBackground(theme.formRowBackground)
      Section {
        TextField("Name", text: $name, prompt: Text("Machine name"))
        Picker("Icon", selection: $icon) {
          ForEach(MachineIcon.choices) { choice in
            Label(choice.title, systemImage: choice.systemImage)
              .tag(choice.systemImage)
          }
        }
        .pickerStyle(.menu)
      }
      .listRowBackground(theme.formRowBackground)
    }
    .formStyle(.grouped)
    .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    .scrollDisabled(true)
    .toolbar {
      if let onDisconnect {
        ToolbarItem(placement: .destructiveAction) {
          Button("Disconnect…", role: .destructive) {
            onDisconnect()
            dismiss()
          }
        }
      }
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          onSave(trimmedName, icon)
          dismiss()
        }
        .disabled(trimmedName.isEmpty)
      }
    }
    .frame(width: 460)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    .themedSurface(.sheet)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9, style: .continuous))
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(trimmedName.isEmpty ? "Machine" : trimmedName)
          .font(.headline)
          .lineLimit(1)
        Text(isLocal ? "This Mac" : "Codevisor Cloud")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}
