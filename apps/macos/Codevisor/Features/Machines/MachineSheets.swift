import SwiftUI
import CodevisorCore

/// Sheet for adding a remote machine by host, with an optional display name.
/// Used from the toolbar's machine picker and the Machines settings tab.
struct RemoteMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name: String
    @State private var host: String
    @State private var token = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    /// Validates and adds the machine; returns an error message to show
    /// inline, or nil on success (the sheet then dismisses).
    let onAdd: (String, String?, String?) async -> String?

    /// Prefill support for discovered machines: name and host arrive from the
    /// tailnet probe, the token still has to come from the machine's owner.
    init(
        name: String = "",
        host: String = "",
        onAdd: @escaping (String, String?, String?) async -> String?
    ) {
        _name = State(initialValue: name)
        _host = State(initialValue: host)
        self.onAdd = onAdd
    }

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
            labeledField("Connection token", hint: "Run `codevisor token` on the machine (or copy it from its setup output) and paste it here.") {
                TextField("hm_…", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .disabled(isAdding)
                Button("Add") { submit() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedHost.isEmpty || isAdding)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        isAdding = true
        errorMessage = nil
        Task {
            let failure = await onAdd(trimmedHost, trimmedName, trimmedToken.isEmpty ? nil : trimmedToken)
            isAdding = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }

    private func labeledField(_ title: String, hint: String? = nil, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            field()
            // The hint sits inline (always visible, wrapping) rather than
            // behind a hover tooltip — instantly readable and no popover.
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(hint)
            }
        }
    }
}

/// Sheet for renaming an existing remote machine.
struct RenameMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name: String
    let machine: CodevisorMachine
    let onRename: (String) -> Void

    init(machine: CodevisorMachine, onRename: @escaping (String) -> Void) {
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
