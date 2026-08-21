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
    @State private var activeSheet: PluginsSheet?
    @State private var pluginPendingRemoval: ServerPluginSummary?
    @State private var isMutating = false

    /// One sheet slot for both flows, so "Install" inside the browse sheet
    /// can swap straight into the install sheet's discover→consent stages.
    private enum PluginsSheet: Identifiable {
        case install(initialSource: String?)
        case browse
        var id: String {
            switch self {
            case .install: "install"
            case .browse: "browse"
            }
        }
    }

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
                    Button("Browse Plugins…") { activeSheet = .browse }
                    Button("Install Plugin…") { activeSheet = .install(initialSource: nil) }
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
                    activeSheet = .browse
                } label: {
                    Label("Browse Plugins", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .install(initialSource: nil)
                } label: {
                    Label("Install Plugin", systemImage: "plus")
                }
            }
        }
        .task(id: serverId) { await reload() }
        // plugin.state.updated events (start, crash, restart, and list
        // changes) bump the revision; refetch the light list.
        .onChange(of: environment.pluginStateRevision(for: serverId)) { _, _ in
            Task { await refreshList() }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .install(let initialSource):
                PluginInstallSheet(
                    initialSource: initialSource,
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
            case .browse:
                PluginRegistryBrowseSheet(
                    fetchRegistry: { try await client.fetchPluginRegistry(query: nil) },
                    installedIds: Set((plugins ?? []).map(\.id)),
                    onInstall: { entry in
                        // The registry only discovers; installing goes
                        // through the existing consent flow with the entry's
                        // repo as the source.
                        activeSheet = .install(initialSource: entry.repo)
                    }
                )
            }
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
            PluginIconView(
                pluginId: plugin.id,
                iconPath: plugin.iconPath,
                client: client,
                cacheNamespace: serverId,
                fallbackSystemName: "puzzlepiece"
            )
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
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
/// A registry selection arrives as `initialSource` (the entry's repo) and
/// auto-discovers — skipping the typing, never the consent.
private struct PluginInstallSheet: View {
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
        .task {
            if let initialSource, discovery == nil {
                source = initialSource
                await find()
            }
        }
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
                        Label(pane.title, systemImage: "puzzlepiece")
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

/// Browse the public plugin registry: a searchable list of GitHub-indexed
/// plugins served through this machine (`GET /v1/plugins/registry`). Purely
/// discovery — Install hands the entry's repo to the existing install sheet,
/// so consent (verbatim commands + declared tools) is unchanged. The iOS
/// twin of macOS's PluginRegistryBrowseSheet.
private struct PluginRegistryBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fetchRegistry: () async throws -> ServerPluginRegistryIndex
    let installedIds: Set<String>
    let onInstall: (ServerPluginRegistryEntry) -> Void

    @State private var entries: [ServerPluginRegistryEntry]?
    @State private var errorMessage: String?
    @State private var query = ""

    private var filtered: [ServerPluginRegistryEntry] {
        PluginRegistryBrowsing.filter(entries ?? [], query: query)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Browse Plugins")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let entries {
            List {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Plugins Published", systemImage: "puzzlepiece")
                    } description: {
                        Text("No plugins have been published to the registry yet.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("Plugin Registry") {
                        ForEach(filtered) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search plugins")
        } else if let errorMessage {
            // Registry unreachable and nothing cached server-side: browsing
            // is unavailable, but manual installs still work.
            ContentUnavailableView {
                Label("Registry Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else {
            ProgressView()
                .accessibilityLabel("Loading the plugin registry")
        }
    }

    private func entryRow(_ entry: ServerPluginRegistryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                    Text(entry.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if PluginRegistryBrowsing.isInstalled(entry, installedIds: installedIds) {
                        Text("Installed")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Install…") { onInstall(entry) }
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(subtitle(entry))")
    }

    /// One line, densest first: the real repo owner, what installing adds,
    /// and the GitHub stars that anchor the entry's reputation.
    private func subtitle(_ entry: ServerPluginRegistryEntry) -> String {
        let capabilities = PluginRegistryBrowsing.capabilitySummary(for: entry)
        let stars = "\(entry.stars) star\(entry.stars == 1 ? "" : "s")"
        return ([entry.repo, capabilities, stars].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    private func load() async {
        do {
            entries = try await fetchRegistry().entries
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
