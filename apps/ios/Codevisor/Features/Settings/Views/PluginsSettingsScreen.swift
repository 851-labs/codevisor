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
    @State private var updates: [String: ServerPluginUpdateStatus] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var activeSheet: PluginsSheet?
    @State private var pluginPendingRestore: ServerPluginSummary?
    @State private var isMutating = false

    /// One sheet slot for both flows, so "Install" inside the browse sheet
    /// can swap straight into the install sheet's discover→consent stages.
    private enum PluginsSheet: Identifiable {
        case install(initialSource: String?)
        case browse
        case update(ServerPluginUpdatePlan)
        var id: String {
            switch self {
            case .install: "install"
            case .browse: "browse"
            case .update(let plan): "update:\(plan.planId)"
            }
        }
    }

    /// Phase 24: what each machine reports for the fleet's plugins.
    @ViewBuilder
    private var machinesSection: some View {
        let _ = environment.configSync.revisionsByNamespace["plugin-readiness"]
        let readiness = PluginFleet.readiness(environment.configSync)
        if environment.machines.allMachines.count > 1, !readiness.isEmpty {
            Section("On Your Machines") {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    let rows = readiness[machineId] ?? []
                    DisclosureGroup {
                        ForEach(rows) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.pluginId)
                                Text(entry.reason ?? entry.state)
                                    .font(.footnote)
                                    .foregroundStyle(
                                        entry.state == "blocked" ? .orange : .secondary)
                            }
                        }
                    } label: {
                        HStack {
                            Text(environment.machines.fleetMachineName(for: machineId) ?? machineId)
                            Spacer(minLength: 12)
                            pluginBadge(rows).view
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func pluginBadge(_ rows: [PluginFleet.MachineReadiness]) -> MachineSyncBadge {
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "notInstalled" }) { return .syncing }
        return .synced
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
                // Custom empty state (not ContentUnavailableView): it packs
                // its actions right against the title. Manual installs stay
                // reachable from the toolbar's + button.
                VStack(spacing: 16) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 42))
                        .foregroundStyle(.tertiary)
                    Text("No Plugins Installed")
                        .font(.title3.weight(.semibold))
                    Button("Browse Plugins") { activeSheet = .browse }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                Section("Installed") {
                    ForEach(plugins ?? []) { plugin in
                        pluginRow(plugin)
                    }
                }
                machinesSection
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
            case .update(let plan):
                PluginUpdateSheet(
                    plan: plan,
                    onApply: {
                        _ = try await mutate {
                            try await client.applyPluginUpdate(
                                pluginId: plan.pluginId,
                                planId: plan.planId
                            )
                        }
                        await reload()
                    }
                )
            }
        }
        .confirmationDialog(
            "Restore " + (pluginPendingRestore?.name ?? "plugin") + "?",
            isPresented: Binding(
                get: { pluginPendingRestore != nil },
                set: { if !$0 { pluginPendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Previous Version") {
                guard let plugin = pluginPendingRestore else { return }
                Task {
                    _ = try? await mutate {
                        try await client.restorePlugin(pluginId: plugin.id)
                    }
                    pluginPendingRestore = nil
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) { pluginPendingRestore = nil }
        } message: {
            Text(
                "This restores the verified pre-update code and data. The current version becomes the next restore point."
            )
        }
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
                    stateChip(pluginRuntimeState(plugin))
                    if let update = updates[plugin.id] {
                        updateChip(update)
                    }
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
        .accessibilityLabel(accessibilityLabel(for: plugin))
        .contextMenu {
            pluginActions(plugin)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if updates[plugin.id]?.state == .available {
                Button {
                    prepareUpdate(plugin)
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
            // Only managed installs may be uninstalled — a linked dev
            // plugin's directory belongs to its author.
            if plugin.source == "managed" {
                Button(role: .destructive) {
                    uninstall(plugin)
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
            }
            if plugin.isEnabled {
                Button {
                    restart(plugin)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    /// The per-plugin actions, shared by the row's ellipsis menu and its
    /// long-press context menu so both surfaces always agree.
    @ViewBuilder
    private func pluginActions(_ plugin: ServerPluginSummary) -> some View {
        if updates[plugin.id]?.state == .available {
            Button {
                prepareUpdate(plugin)
            } label: {
                Label("Update…", systemImage: "arrow.down.circle")
            }
        }
        if updates[plugin.id]?.state == .sourceUnknown {
            Button {
                activeSheet = .install(initialSource: nil)
            } label: {
                Label("Reinstall to Enable Updates…", systemImage: "arrow.clockwise.circle")
            }
        }
        if plugin.canRestore == true {
            Button {
                pluginPendingRestore = plugin
            } label: {
                Label("Restore Previous Version…", systemImage: "clock.arrow.circlepath")
            }
        }
        Button {
            setEnabled(plugin, enabled: !plugin.isEnabled)
        } label: {
            Label(
                plugin.isEnabled ? "Disable" : "Enable", systemImage: plugin.isEnabled ? "pause.circle" : "play.circle")
        }
        if plugin.isEnabled {
            Button {
                restart(plugin)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
        }
        // Only managed installs may be uninstalled — a linked dev plugin's
        // directory belongs to its author.
        if plugin.source == "managed" {
            Button(role: .destructive) {
                uninstall(plugin)
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
    }

    private func restart(_ plugin: ServerPluginSummary) {
        Task {
            _ = try? await mutate {
                try await client.restartPlugin(pluginId: plugin.id)
            }
            await refreshList()
        }
    }

    private func setEnabled(_ plugin: ServerPluginSummary, enabled: Bool) {
        Task {
            _ = try? await mutate {
                try await client.setPluginEnabled(pluginId: plugin.id, enabled: enabled)
            }
            await refreshList()
        }
    }

    /// Uninstalls immediately — the destructive swipe/menu styling is the
    /// signal; failures still surface in the action banner.
    private func uninstall(_ plugin: ServerPluginSummary) {
        Task {
            if let refreshed = try? await mutate({
                try await client.removePlugin(pluginId: plugin.id)
            }) {
                plugins = refreshed
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

    private func updateChip(_ update: ServerPluginUpdateStatus) -> some View {
        Text(updateTitle(update))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .foregroundStyle(updateStyle(update.state))
    }

    private func updateTitle(_ update: ServerPluginUpdateStatus) -> String {
        switch update.state {
        case .current: "Current"
        case .available: "Update \(update.registryVersion ?? "available")"
        case .pinned: "Pinned"
        case .incompatible: "Incompatible"
        case .sourceUnknown: "Source unknown"
        case .checkFailed: "Check failed"
        }
    }

    private func updateStyle(_ state: ServerPluginUpdateState) -> AnyShapeStyle {
        switch state {
        case .current: AnyShapeStyle(.green)
        case .available: AnyShapeStyle(.blue)
        case .incompatible, .checkFailed: AnyShapeStyle(.orange)
        case .pinned, .sourceUnknown: AnyShapeStyle(.secondary)
        }
    }

    private func accessibilityLabel(for plugin: ServerPluginSummary) -> String {
        guard let update = updates[plugin.id] else {
            return "\(plugin.name), \(pluginRuntimeState(plugin)), \(sourceText(plugin))"
        }
        return "\(plugin.name), \(pluginRuntimeState(plugin)), \(updateTitle(update)), \(sourceText(plugin))"
    }

    private func prepareUpdate(_ plugin: ServerPluginSummary) {
        Task {
            if let plan = try? await mutate({
                try await client.preparePluginUpdate(pluginId: plugin.id)
            }) {
                activeSheet = .update(plan)
            }
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
            do {
                let statuses = try await client.listPluginUpdates()
                updates = Dictionary(uniqueKeysWithValues: statuses.map { ($0.pluginId, $0) })
            } catch {
                // Keep installed plugins usable against older servers and
                // through transient registry outages.
                updates = [:]
            }
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

private func pluginRuntimeState(_ plugin: ServerPluginSummary) -> String {
    plugin.isEnabled ? plugin.state : "disabled"
}
