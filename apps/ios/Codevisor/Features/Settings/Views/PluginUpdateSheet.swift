import CodevisorCore
import SwiftUI

/// Reviews the exact staged candidate before applying its short-lived plan.
struct PluginUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: ServerPluginUpdatePlan
    let onApply: () async throws -> Void
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                overview
                commands(title: "Current Commands", review: plan.current)
                commands(title: "Update Commands", review: plan.candidate)
                requirements
                changes
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review Update")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isWorking)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Update") { Task { await apply() } }
                    }
                }
            }
        }
    }

    private var overview: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.name).font(.headline)
                Text("\(plan.current.version) → \(plan.candidate.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Plugin", value: plan.pluginId)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resolved commit").font(.footnote).foregroundStyle(.secondary)
                Text(verbatim: plan.resolvedCommit)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        } footer: {
            Text("Codevisor applies these exact staged bytes. An expired or stale plan must be reviewed again.")
        }
    }

    private func commands(title: String, review: ServerPluginUpdateReview) -> some View {
        Section(title) {
            if review.setupCommands.isEmpty {
                LabeledContent("Setup", value: "None")
            } else {
                ForEach(Array(review.setupCommands.enumerated()), id: \.offset) { index, command in
                    commandRow(title: "Setup \(index + 1)", command: command)
                }
            }
            commandRow(title: "Run", command: review.runCommand)
        }
    }

    @ViewBuilder
    private var requirements: some View {
        let executables = plan.candidate.requirements?.executables ?? []
        Section("Requirements") {
            if executables.isEmpty {
                Text("None declared").foregroundStyle(.secondary)
            } else {
                ForEach(executables) { requirement in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(requirement.name).font(.callout.monospaced())
                        if let hint = requirement.installHint {
                            Text(hint).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let rawUrl = requirement.helpUrl, let url = URL(string: rawUrl) {
                            Link("Setup instructions", destination: url).font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private var changes: some View {
        Section("Capability Changes") {
            changeRows(label: "Pane", changes: plan.paneChanges)
            changeRows(label: "Tool", changes: plan.toolChanges)
        }
    }

    @ViewBuilder
    private func changeRows(label: String, changes: ServerPluginNamedChanges) -> some View {
        if changes.added.isEmpty, changes.removed.isEmpty, changes.changed.isEmpty {
            LabeledContent(label, value: "No changes")
        } else {
            ForEach(changes.added, id: \.self) { name in
                Label("Add \(label.lowercased()) “\(name)”", systemImage: "plus.circle")
                    .foregroundStyle(.green)
            }
            ForEach(changes.changed, id: \.self) { name in
                Label("Change \(label.lowercased()) “\(name)”", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            ForEach(changes.removed, id: \.self) { name in
                Label("Remove \(label.lowercased()) “\(name)”", systemImage: "minus.circle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }

    private func apply() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await onApply()
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
