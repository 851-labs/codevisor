import CodevisorCore
import CodevisorUI
import SwiftUI

/// Sheet for renaming a machine connected to the cloud account.
struct RenameCloudMachineSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  @State private var name: String
  let machine: CloudMachine
  let onRename: (String) -> Void

  init(machine: CloudMachine, onRename: @escaping (String) -> Void) {
    self.machine = machine
    self.onRename = onRename
    _name = State(initialValue: machine.name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename machine")
        .font(.headline)
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
      Text(machine.deviceId)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .settingsActionTint(theme)
        Button("Save") {
          onRename(name)
          dismiss()
        }
        .settingsActionTint(theme)
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
