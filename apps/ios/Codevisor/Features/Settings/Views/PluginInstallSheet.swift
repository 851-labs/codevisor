import CodevisorCore
import CodevisorUI
import SwiftUI

/// Two-stage install, mirroring macOS's PluginInstallSheet: enter a source,
/// discover what it offers, then consent to the exact commands it will run.
/// A registry selection arrives as `initialSource` (the entry's repo) and
/// auto-discovers — skipping the typing, never the consent. Internal (not
/// private) because the codevisor://install-plugin deeplink presents it
/// straight from Home, outside any settings navigation.
struct PluginInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    var initialSource: String?
    let discover: (String) async throws -> ServerPluginRemoteDiscovery
    let onInstall: (String) async throws -> Void

    @State private var source = ""
    @State private var discovery: ServerPluginRemoteDiscovery?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // The source field only exists while typing one — once a
                // plugin is found, the consent stage shows the plugin itself
                // (Back returns here to edit).
                if discovery == nil {
                    Section {
                        // Verbatim prompt: the LocalizedStringKey initializer
                        // would markdown-link a bare repo prompt.
                        TextField(
                            "Source",
                            text: $source,
                            prompt: Text(verbatim: "owner/repo, a git URL, or a local path")
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await find() } }
                    } footer: {
                        Text("A public GitHub repo, a git URL, or a path on the machine.")
                    }
                }
                if let discovery {
                    discoverySections(discovery)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle("Install Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if discovery == nil {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") {
                            discovery = nil
                            errorMessage = nil
                        }
                        .disabled(isWorking)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // HIG loading state: the action is replaced by an
                    // indeterminate spinner while it runs — never a
                    // relabeled, still-tappable-looking button.
                    if isWorking {
                        ProgressView()
                    } else if discovery == nil {
                        Button("Find") {
                            Task { await find() }
                        }
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button("Install") {
                            Task { await runInstall() }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task {
            if let initialSource, discovery == nil {
                source = initialSource
                await find()
            }
        }
    }

    /// The consent stage, structured like the registry detail screen: what
    /// the plugin is, what it adds, and — verbatim — what it will run.
    @ViewBuilder
    private func discoverySections(_ discovery: ServerPluginRemoteDiscovery) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(discovery.name)
                        .font(.headline)
                    Text(discovery.version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let description = discovery.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if discovery.alreadyInstalled {
                Label("Already installed — installing updates it.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Details") {
            LabeledContent("Source", value: source.trimmingCharacters(in: .whitespaces))
            if !discovery.panes.isEmpty {
                LabeledContent(
                    "Panes",
                    value: discovery.panes.map(\.title).joined(separator: ", ")
                )
            }
        }
        // Declared agent tools are part of what the user consents to, next
        // to the verbatim commands below.
        if let tools = discovery.tools, !tools.isEmpty {
            Section("Agent Tools") {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.callout.monospaced())
                        Text(tool.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        Section {
            // The verbatim manifest commands — exactly what will run, never
            // a summary.
            if let install = discovery.installCommand {
                commandRow(title: "Install", command: install)
            }
            commandRow(title: "Run", command: discovery.runCommand)
        } header: {
            Text("Commands")
        } footer: {
            Text("Installing runs these commands on the machine.")
        }
    }

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func find() async {
        isWorking = true
        defer { isWorking = false }
        do {
            discovery = try await discover(source.trimmingCharacters(in: .whitespaces))
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func runInstall() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await onInstall(source.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
