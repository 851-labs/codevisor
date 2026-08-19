import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import os

// MARK: - Plugins

/// Settings ▸ Machines ▸ <machine> ▸ Plugins: the plugins installed on one
/// machine, with live runtime-state chips, restart/uninstall actions, and a
/// two-stage install sheet that shows the exact commands a plugin will run
/// before anything executes. The iOS twin of macOS's PluginsSettingsView,
/// modeled on SkillsSettingsScreen.
struct PluginsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let client: any CodevisorServerClienting
    /// The machine whose plugins this screen manages, for
    /// `plugin.state.updated` revision observation.
    let serverId: String

    @State private var plugins: [ServerPluginSummary]?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var showingInstall = false
    @State private var pluginPendingRemoval: ServerPluginSummary?
    @State private var isMutating = false

    var body: some View {
        List {
            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if isLoading, plugins == nil {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage, plugins == nil {
                Text(errorMessage).foregroundStyle(.red)
            } else if (plugins ?? []).isEmpty {
                ContentUnavailableView {
                    Label("No Plugins", systemImage: "puzzlepiece")
                } description: {
                    Text("Plugins add custom panes to your workspaces, served by this machine.")
                } actions: {
                    Button("Install Plugin…") { showingInstall = true }
                }
            } else {
                Section("Installed") {
                    ForEach(plugins ?? []) { plugin in
                        pluginRow(plugin)
                    }
                }
            }
        }
        .disabled(isMutating)
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInstall = true
                } label: {
                    Label("Install Plugin", systemImage: "plus")
                }
            }
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
            Button("Cancel", role: .cancel) { pluginPendingRemoval = nil }
        } message: {
            Text(removalMessage(for: pluginPendingRemoval))
        }
    }

    /// The uninstall consequences, including the panes the server will close
    /// (`openPaneCount` route enrichment) so users aren't surprised when
    /// tabs disappear on every device.
    private func removalMessage(for plugin: ServerPluginSummary?) -> String {
        let base = "This stops the plugin and deletes its directory from the machine."
        guard let count = plugin?.openPaneCount, count > 0 else { return base }
        return "\(base) \(count) open pane\(count == 1 ? "" : "s") will be closed."
    }

    private func pluginRow(_ plugin: ServerPluginSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: plugin.panes.first?.icon ?? "puzzlepiece")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name)
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
                if let description = plugin.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(plugin.name), \(plugin.state), \(sourceText(plugin))")
        .contextMenu {
            Button {
                Task {
                    _ = try? await mutate {
                        try await client.restartPlugin(pluginId: plugin.id)
                    }
                    await refreshList()
                }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            // Only managed installs may be uninstalled — a linked dev
            // plugin's directory belongs to its author.
            if plugin.source == "managed" {
                Button(role: .destructive) {
                    pluginPendingRemoval = plugin
                } label: {
                    Label("Uninstall…", systemImage: "trash")
                }
            }
        }
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
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .foregroundStyle(stateStyle(state))
    }

    private func stateStyle(_ state: String) -> AnyShapeStyle {
        switch state {
        case "running": AnyShapeStyle(.green)
        case "failed": AnyShapeStyle(.red)
        case "starting", "stopping": AnyShapeStyle(.orange)
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
    /// rethrow so the install sheet can stay open.
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

/// Two-stage install, mirroring macOS's PluginInstallSheet: enter a source,
/// discover what it offers, then consent to the exact commands it will run.
private struct PluginInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let discover: (String) async throws -> ServerPluginRemoteDiscovery
    let onInstall: (String) async throws -> Void

    @State private var source = ""
    @State private var discovery: ServerPluginRemoteDiscovery?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Install Plugin") {
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
                    .disabled(discovery != nil)
                }
                if let discovery {
                    discoverySections(discovery)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
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
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if discovery == nil {
                        Button(isWorking ? "Finding…" : "Find") {
                            Task { await find() }
                        }
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    } else {
                        Button(isWorking ? "Installing…" : "Install") {
                            Task { await runInstall() }
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    @ViewBuilder
    private func discoverySections(_ discovery: ServerPluginRemoteDiscovery) -> some View {
        Section("Plugin") {
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(discovery.panes) { pane in
                        Label(pane.title, systemImage: pane.icon ?? "puzzlepiece")
                            .font(.callout)
                    }
                }
            }
            // Declared agent tools are part of what the user consents to,
            // next to the verbatim commands below.
            if let tools = discovery.tools, !tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
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
        }
        Section {
            // The verbatim manifest commands — exactly what will run, never
            // a summary.
            VStack(alignment: .leading, spacing: 4) {
                if let install = discovery.installCommand {
                    Text(verbatim: "install: \(install)")
                }
                Text(verbatim: "run: \(discovery.runCommand)")
            }
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            Label(
                "This will run these commands on the machine.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } header: {
            Text("Commands")
        }
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
