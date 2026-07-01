import SwiftUI
import HerdManCore

/// Sheet for adding a remote machine by host, with an optional display name.
/// Used from the sidebar's machine picker and the Machines settings tab.
struct RemoteMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var name = ""
    let onAdd: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add remote machine")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Address")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("mac-mini.tailnet.ts.net or 100.64.0.10:49361", text: $host)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Optional, e.g. Mac mini", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(host, trimmedName.isEmpty ? nil : trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Sheet for renaming an existing remote machine.
struct RenameMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let machine: HerdManMachine
    let onRename: (String) -> Void

    init(machine: HerdManMachine, onRename: @escaping (String) -> Void) {
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
            Text(machine.baseURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
