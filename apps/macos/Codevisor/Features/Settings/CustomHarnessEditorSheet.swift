import SwiftUI
import CodevisorCore

/// Add/edit form for a user-defined custom ACP harness, with an ACP
/// handshake "Test Connection" probe. The server persists entries in the
/// user-editable ~/.codevisor/harnesses.json and merges them into the
/// catalog live — no restart needed.
struct CustomHarnessEditorSheet: View {
    /// Existing entry id when editing; nil when adding a new harness.
    let editingId: String?
    /// Receives the refreshed full harness list after a successful save or
    /// delete so the settings pane updates without a rescan round-trip.
    let onSaved: ([ServerHarness]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var identifier = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var envText = ""
    /// All persisted specs, loaded on appear — a save rewrites the whole
    /// list, so entries other than the edited one must be preserved.
    @State private var existingSpecs: [ServerCustomHarnessSpec] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: ServerCustomHarnessTestResult?
    @State private var errorMessage: String?
    @State private var confirmsDelete = false

    private var isEditing: Bool { editingId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Custom Harness" : "Add Custom Harness")
                .font(.headline)
            Text("Any agent that speaks ACP over stdio. Codevisor runs the command below and talks ACP to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text("My Agent"))
                    TextField("Identifier", text: $identifier, prompt: Text("my-agent"))
                        .disabled(isEditing)
                    TextField("Command", text: $command, prompt: Text("/path/to/agent"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Arguments", text: $argsText, prompt: Text("acp"))
                        .font(.system(.body, design: .monospaced))
                    TextField(
                        "Environment",
                        text: $envText,
                        prompt: Text("KEY=value, one per line"),
                        axis: .vertical
                    )
                    .lineLimit(1 ... 4)
                    .font(.system(.body, design: .monospaced))
                }
                .formStyle(.columns)

                if let testResult {
                    testResultRow(testResult)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(theme.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if isEditing {
                    Button("Delete…", role: .destructive) { confirmsDelete = true }
                        .disabled(isSaving || isTesting)
                }
                Button {
                    Task { await test() }
                } label: {
                    if isTesting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(command.trimmed.isEmpty || isSaving || isTesting)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                    } else {
                        Text(isEditing ? "Save" : "Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving || isTesting)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .task { await loadIfEditing() }
        .confirmationDialog(
            "Remove \(name.trimmed.isEmpty ? "this harness" : name)?",
            isPresented: $confirmsDelete
        ) {
            Button("Remove Harness", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Existing chats keep their history; the harness disappears from the picker.")
        }
    }

    // MARK: - Form state

    private var canSave: Bool {
        !name.trimmed.isEmpty && !command.trimmed.isEmpty && !(resolvedIdentifier.isEmpty)
    }

    /// Explicit identifier, or a slug derived from the name when adding.
    private var resolvedIdentifier: String {
        let explicit = identifier.trimmed
        if !explicit.isEmpty { return explicit }
        return name.trimmed
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                if character == "-" && partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var draftSpec: ServerCustomHarnessSpec {
        let args = argsText.split(whereSeparator: \.isWhitespace).map(String.init)
        var env: [String: String] = [:]
        for line in envText.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmed
            let value = String(line[line.index(after: separator)...])
            if !key.isEmpty { env[key] = value }
        }
        return ServerCustomHarnessSpec(
            id: editingId ?? resolvedIdentifier,
            name: name.trimmed,
            command: command.trimmed,
            args: args.isEmpty ? nil : args,
            env: env.isEmpty ? nil : env
        )
    }

    private func testResultRow(_ result: ServerCustomHarnessTestResult) -> some View {
        Label {
            if result.ok {
                let identity = [
                    result.agentName,
                    result.protocolVersion.map { "ACP v\($0)" }
                ].compactMap(\.self).joined(separator: " · ")
                Text(identity.isEmpty ? "Connected" : "Connected: \(identity)")
            } else {
                Text(result.error ?? "Connection failed")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.ok ? AnyShapeStyle(theme.statusOK) : AnyShapeStyle(theme.statusWarn))
        }
        .font(.callout)
    }

    // MARK: - Server calls

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: environment.machines.selectedMachineId)
    }

    private func loadIfEditing() async {
        isLoading = true
        defer { isLoading = false }
        do {
            existingSpecs = try await client.listCustomHarnesses()
        } catch {
            // Adding still works from an empty list; editing without the list
            // would clobber siblings, so surface the failure.
            if isEditing { errorMessage = "Couldn't load custom harnesses: \(error.localizedDescription)" }
            return
        }
        guard let editingId, let spec = existingSpecs.first(where: { $0.id == editingId }) else { return }
        name = spec.name
        identifier = spec.id
        command = spec.command
        argsText = (spec.args ?? []).joined(separator: " ")
        envText = (spec.env ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private func test() async {
        isTesting = true
        testResult = nil
        errorMessage = nil
        defer { isTesting = false }
        do {
            testResult = try await client.testCustomHarness(draftSpec)
        } catch {
            errorMessage = "Test failed: \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let spec = draftSpec
        var specs = existingSpecs.filter { $0.id != spec.id }
        specs.append(spec)
        await replace(with: specs)
    }

    private func delete() async {
        guard let editingId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        await replace(with: existingSpecs.filter { $0.id != editingId })
    }

    private func replace(with specs: [ServerCustomHarnessSpec]) async {
        do {
            let harnesses = try await client.replaceCustomHarnesses(specs)
            onSaved(harnesses)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    CustomHarnessEditorSheet(editingId: nil) { _ in }
        .environment(AppEnvironment.preview())
}
