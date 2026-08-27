import CodevisorCore
import CodevisorUI
import SwiftUI

/// New-skill form: name + description, and an optional text area for pasting
/// SKILL.md content directly.
struct SkillCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let onCreate: (String, String, String?) async throws -> Void
    @State private var name = ""
    @State private var skillDescription = ""
    @State private var pastedContent = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("New Skill") {
                    TextField("Name", text: $name, prompt: Text("Deploy checklist"))
                    TextField(
                        "Description",
                        text: $skillDescription,
                        prompt: Text("When to use this skill and what it does"),
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                }
                .listRowBackground(themedFormRowBackground)
                Section("Content") {
                    TextEditor(text: $pastedContent)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Skill content")
                }
                .listRowBackground(themedFormRowBackground)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(theme.statusError)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Creating…" : "Create") {
                    Task { await save() }
                }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 460, height: 420)
        .themedSurface(.sheet)
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmed = pastedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            try await onCreate(name, skillDescription, trimmed.isEmpty ? nil : trimmed)
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

/// Two-stage import: enter a source (GitHub/GitLab repo, git URL, or a site
/// publishing skills), discover what it offers, then import the selection.
struct SkillRemoteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let discover: (String) async throws -> [ServerRemoteSkillCandidate]
    let onImport: (String, [String]?) async throws -> Void
    @State private var source = ""
    @State private var candidates: [ServerRemoteSkillCandidate]?
    @State private var selection: Set<String> = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Import Skills") {
                    // Same labeled-field pattern as the MCP editor's Server
                    // URL row; verbatim because the LocalizedStringKey
                    // initializer would markdown-link a bare URL prompt.
                    TextField(
                        "Source",
                        text: $source,
                        prompt: Text(verbatim: "https://github.com/vercel-labs/skills")
                    )
                    .onSubmit { Task { await find() } }
                    .disabled(candidates != nil)
                }
                .listRowBackground(themedFormRowBackground)
                if let candidates {
                    Section {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    } header: {
                        HStack {
                            Text("Skills Found (\(candidates.count))")
                            Spacer()
                            let selectable = candidates.filter { !$0.alreadyExists }
                            if !selectable.isEmpty {
                                if selection.count == selectable.count {
                                    Button("Deselect All") { selection = [] }
                                        .buttonStyle(.borderless)
                                        .settingsActionTint(theme)
                                } else {
                                    Button("Select All") {
                                        selection = Set(selectable.map(\.directoryName))
                                    }
                                    .buttonStyle(.borderless)
                                    .settingsActionTint(theme)
                                }
                            }
                        }
                    }
                    .listRowBackground(themedFormRowBackground)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(theme.statusError)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if candidates != nil {
                    Button("Back") {
                        candidates = nil
                        selection = []
                        errorMessage = nil
                    }
                    .settingsActionTint(theme)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                if candidates == nil {
                    Button(isWorking ? "Finding…" : "Find Skills") {
                        Task { await find() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                } else {
                    Button(isWorking ? "Importing…" : importLabel) {
                        Task { await runImport() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || isWorking)
                }
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 480, height: candidates == nil ? 220 : 420)
        .themedSurface(.sheet)
    }

    private var importLabel: String {
        selection.count == 1 ? "Import 1 Skill" : "Import \(selection.count) Skills"
    }

    private func candidateRow(_ candidate: ServerRemoteSkillCandidate) -> some View {
        HStack(spacing: 10) {
            if candidate.alreadyExists {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                Toggle(
                    candidate.name,
                    isOn: Binding(
                        get: { selection.contains(candidate.directoryName) },
                        set: { included in
                            if included {
                                selection.insert(candidate.directoryName)
                            } else {
                                selection.remove(candidate.directoryName)
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .foregroundStyle(candidate.alreadyExists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let description = candidate.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if candidate.alreadyExists {
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private func find() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let found = try await discover(source.trimmingCharacters(in: .whitespaces))
            candidates = found
            // Everything new is pre-selected — one click imports the lot.
            selection = Set(found.filter { !$0.alreadyExists }.map(\.directoryName))
            errorMessage = found.isEmpty ? "No skills found at this source." : nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func runImport() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let names = Array(selection)
            try await onImport(source.trimmingCharacters(in: .whitespaces), names)
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
