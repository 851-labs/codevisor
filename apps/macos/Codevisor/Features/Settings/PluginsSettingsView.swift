import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// Settings ▸ Machines ▸ <machine> ▸ Plugins: the plugins installed on one
/// machine, with live runtime-state chips, restart/uninstall actions, and a
/// two-stage install sheet that shows the exact commands a plugin will run
/// before anything executes. Modeled on SkillsSettingsView.
struct PluginsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.settingsMachineId) private var settingsMachineId
    @State private var plugins: [ServerPluginSummary]?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var showingInstall = false
    @State private var pluginPendingRemoval: ServerPluginSummary?
    @State private var isMutating = false

    /// The machine whose plugins this pane manages.
    private var serverId: String {
        settingsMachineId ?? environment.machines.selectedMachineId
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    var body: some View {
        content
            .background {
                if !theme.isSystem { theme.windowBackground }
            }
            .task(id: serverId) { await reload() }
            // plugin.state.updated events (start, crash, idle stop, list
            // changes) bump the revision; refetch the light list.
            .onChange(of: environment.pluginStateRevision(for: serverId)) { _, _ in
                Task { await refreshList() }
            }
            .sheet(isPresented: $showingInstall) {
                PluginInstallSheet(
                    discover: { source in
                        try await client.discoverRemotePlugin(source: source)
                    },
                    onInstall: { source in
                        _ = try await mutate {
                            try await client.importRemotePlugin(source: source)
                        }
                        await reload()
                    }
                )
            }
            .confirmationDialog(
                "Uninstall \(pluginPendingRemoval?.name ?? "plugin")?",
                isPresented: Binding(
                    get: { pluginPendingRemoval != nil },
                    set: { if !$0 { pluginPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Uninstall Plugin", role: .destructive) {
                    guard let plugin = pluginPendingRemoval else { return }
                    Task {
                        if let refreshed = try? await mutate({
                            try await client.removePlugin(pluginId: plugin.id)
                        }) {
                            plugins = refreshed
                        }
                    }
                }
                .settingsActionTint(theme)
                Button("Cancel", role: .cancel) { pluginPendingRemoval = nil }
                    .settingsActionTint(theme)
            } message: {
                Text(removalMessage(for: pluginPendingRemoval))
            }
    }

    /// The uninstall consequences, including the panes the server will close
    /// (`openPaneCount` route enrichment) so users aren't surprised when
    /// tabs disappear on every device.
    private func removalMessage(for plugin: ServerPluginSummary?) -> String {
        let base = "This stops the plugin and deletes its directory from this machine."
        guard let count = plugin?.openPaneCount, count > 0 else { return base }
        return "\(base) \(count) open pane\(count == 1 ? "" : "s") will be closed."
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, plugins == nil {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.isSystem ? nil : theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading plugins")
        } else if let errorMessage, plugins == nil {
            ContentUnavailableView {
                Label("Plugins Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (plugins ?? []).isEmpty {
            emptyState
        } else {
            pluginsList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Plugins", systemImage: "puzzlepiece")
        } description: {
            Text("Plugins add custom panes to your workspaces, served by this machine.")
        } actions: {
            Button {
                showingInstall = true
            } label: {
                Label("Install Plugin…", systemImage: "plus")
            }
            .settingsActionTint(theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    private var pluginsList: some View {
        Form {
            Section {
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                        .font(.callout)
                }
                ForEach(plugins ?? []) { plugin in
                    pluginRow(plugin)
                }
                Button {
                    showingInstall = true
                } label: {
                    Label("Install Plugin…", systemImage: "plus")
                }
                .settingsActionTint(theme)
            } header: {
                Text("Installed")
            }
        }
        .settingsPaneFormStyle(theme)
        .disabled(isMutating)
    }

    private func pluginRow(_ plugin: ServerPluginSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: plugin.panes.first?.icon ?? "puzzlepiece")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name).foregroundStyle(.primary)
                    Text(plugin.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    stateChip(plugin.state)
                }
                Text(sourceText(plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Restart") {
                    Task {
                        _ = try? await mutate {
                            try await client.restartPlugin(pluginId: plugin.id)
                        }
                        await refreshList()
                    }
                }
                if FileManager.default.fileExists(atPath: plugin.path) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: plugin.path)]
                        )
                    }
                }
                if plugin.source == "managed" {
                    Button("Uninstall…", role: .destructive) { pluginPendingRemoval = plugin }
                }
            } label: {
                Label("More actions for \(plugin.name)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .help(plugin.description ?? plugin.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(plugin.name), \(plugin.state), \(sourceText(plugin))")
    }

    /// One line, one concept: who owns the directory, and where it is.
    private func sourceText(_ plugin: ServerPluginSummary) -> String {
        let ownership = plugin.source == "managed" ? "Managed" : "Linked"
        return "\(ownership) · \(plugin.id)"
    }

    private func stateChip(_ state: String) -> some View {
        Text(state)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
            )
            .foregroundStyle(stateStyle(state))
    }

    private func stateStyle(_ state: String) -> AnyShapeStyle {
        switch state {
        case "running": AnyShapeStyle(theme.statusOK)
        case "failed": AnyShapeStyle(theme.statusError)
        case "starting", "stopping": AnyShapeStyle(theme.statusWarn)
        default: AnyShapeStyle(.secondary)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        await refreshList()
    }

    /// Fetches the plugin list; failures keep the current list and surface in
    /// the unavailable state only when nothing has loaded yet.
    private func refreshList() async {
        do {
            plugins = try await client.listPlugins()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    /// Run one plugin mutation. Failures surface in the action banner and
    /// rethrow so sheets can stay open.
    private func mutate<Value>(_ operation: () async throws -> Value) async throws -> Value {
        isMutating = true
        defer { isMutating = false }
        do {
            let value = try await operation()
            actionError = nil
            return value
        } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
        }
    }
}

/// Two-stage install, forked from SkillRemoteImportSheet: enter a source,
/// discover what it offers, then consent to the exact commands it will run.
private struct PluginInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let discover: (String) async throws -> ServerPluginRemoteDiscovery
    let onInstall: (String) async throws -> Void
    @State private var source = ""
    @State private var discovery: ServerPluginRemoteDiscovery?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Install Plugin") {
                    // Verbatim prompt: the LocalizedStringKey initializer
                    // would markdown-link a bare repo prompt.
                    TextField(
                        "Source",
                        text: $source,
                        prompt: Text(verbatim: "owner/repo, a git URL, or a local path")
                    )
                    .onSubmit { Task { await find() } }
                    .disabled(discovery != nil)
                }
                .listRowBackground(themedFormRowBackground)
                if let discovery {
                    Section {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(discovery.name)
                                Text(discovery.version)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(discovery.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let description = discovery.description {
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !discovery.panes.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(discovery.panes) { pane in
                                    Label(pane.title, systemImage: pane.icon ?? "puzzlepiece")
                                        .font(.callout)
                                }
                            }
                        }
                        // Declared agent tools are part of what the user
                        // consents to, next to the verbatim commands below.
                        if let tools = discovery.tools, !tools.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Adds \(tools.count) agent tool\(tools.count == 1 ? "" : "s"):")
                                    .font(.callout)
                                ForEach(tools) { tool in
                                    Text(verbatim: "\(tool.name) — \(tool.description)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if discovery.alreadyInstalled {
                            Label(
                                "A plugin with this id is already installed; installing will update it.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Plugin")
                    }
                    .listRowBackground(themedFormRowBackground)
                    Section {
                        commandsBox(discovery)
                        Label(
                            "This will run these commands on your machine.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(theme.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                    } header: {
                        Text("Commands")
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
                if discovery != nil {
                    Button("Back") {
                        discovery = nil
                        errorMessage = nil
                    }
                    .settingsActionTint(theme)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                if discovery == nil {
                    Button(isWorking ? "Finding…" : "Find Plugin") {
                        Task { await find() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                } else {
                    Button(isWorking ? "Installing…" : "Install") {
                        Task { await runInstall() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                }
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 480, height: discovery == nil ? 200 : 480)
        .themedSurface(.sheet)
    }

    /// The verbatim manifest commands in a code box — exactly what will run,
    /// never a summary.
    private func commandsBox(_ discovery: ServerPluginRemoteDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let install = discovery.installCommand {
                Text(verbatim: "install: \(install)")
            }
            Text(verbatim: "run: \(discovery.runCommand)")
        }
        .font(.body.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
        )
        .textSelection(.enabled)
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

#Preview("Plugins Settings") {
    PluginsSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
