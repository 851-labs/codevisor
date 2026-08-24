import CodevisorCore
import CodevisorUI
import SwiftUI

/// Two-stage install: enter a source, discover what it offers, then consent
/// to the exact commands it will run. A registry selection auto-discovers,
/// skipping the typing but never the consent.
struct PluginInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var initialSource: String?
    let discover: (String) async throws -> ServerPluginRemoteDiscovery
    let onInstall: (String) async throws -> Void
    @State private var source = ""
    @State private var discovery: ServerPluginRemoteDiscovery?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // The source field only exists while typing one — once a
                // plugin is found, the consent stage shows the plugin itself.
                if discovery == nil {
                    Section {
                        TextField(
                            "Source",
                            text: $source,
                            prompt: Text(verbatim: "owner/repo, a git URL, or a local path")
                        )
                        .onSubmit { Task { await find() } }
                    } header: {
                        Text("Install Plugin")
                    } footer: {
                        Text("A public GitHub repo, a git URL, or a path on this machine.")
                    }
                    .listRowBackground(themedFormRowBackground)
                }
                if let discovery {
                    discoverySections(discovery)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(theme.statusError)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            .disabled(isWorking)
            Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if discovery != nil {
                    Button("Back") {
                        discovery = nil
                        errorMessage = nil
                    }
                    .settingsActionTint(theme)
                    .disabled(isWorking)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.isSystem ? nil : theme.accent)
                        .padding(.horizontal, 12)
                } else if discovery == nil {
                    Button("Find Plugin") { Task { await find() } }
                        .settingsActionTint(theme)
                        .keyboardShortcut(.defaultAction)
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Install") { Task { await runInstall() } }
                        .settingsActionTint(theme)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 480, height: discovery == nil ? 220 : 480)
        .themedSurface(.sheet)
        .task {
            if let initialSource, discovery == nil {
                source = initialSource
                await find()
            }
        }
    }

    @ViewBuilder
    private func discoverySections(_ discovery: ServerPluginRemoteDiscovery) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(discovery.name).font(.headline)
                    Text(discovery.version).font(.subheadline).foregroundStyle(.secondary)
                }
                if let description = discovery.description, !description.isEmpty {
                    Text(description).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if discovery.alreadyInstalled {
                Label("Already installed — installing updates it.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(themedFormRowBackground)
        Section("Details") {
            LabeledContent("Source", value: source.trimmingCharacters(in: .whitespaces))
            if !discovery.panes.isEmpty {
                LabeledContent("Panes", value: discovery.panes.map(\.title).joined(separator: ", "))
            }
        }
        .listRowBackground(themedFormRowBackground)
        if let tools = discovery.tools, !tools.isEmpty {
            Section("Agent Tools") {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.callout.monospaced())
                        Text(tool.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 1)
                }
            }
            .listRowBackground(themedFormRowBackground)
        }
        Section {
            if let install = discovery.installCommand {
                commandRow(title: "Install", command: install)
            }
            commandRow(title: "Run", command: discovery.runCommand)
        } header: {
            Text("Commands")
        } footer: {
            Text("Installing runs these commands on this machine.")
        }
        .listRowBackground(themedFormRowBackground)
    }

    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: command).font(.footnote.monospaced()).textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
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
