import SwiftUI
import HerdManCore

/// Sheet for adding a remote machine by host, with an optional display name.
/// Used from the sidebar's machine picker and the Machines settings tab.
struct RemoteMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var host = ""
    @State private var token = ""
    let onAdd: (String, String?, String?) -> Void

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add remote machine")
                .font(.headline)
            labeledField("Name") {
                TextField("Mac mini", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            labeledField("Host") {
                TextField("100.64.0.10", text: $host)
                    .textFieldStyle(.roundedBorder)
            }
            labeledField("Connection token", hint: "Copy it from Settings → General → Remote Access on the other machine.") {
                TextField("hm_…", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                Button("Add") {
                    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(trimmedHost, trimmedName, trimmedToken.isEmpty ? nil : trimmedToken)
                    dismiss()
                }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedHost.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func labeledField(_ title: String, hint: String? = nil, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if let hint {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(hint)
                        .accessibilityLabel(hint)
                }
            }
            field()
        }
    }
}

/// Sheet for renaming an existing remote machine.
struct RenameMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
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
