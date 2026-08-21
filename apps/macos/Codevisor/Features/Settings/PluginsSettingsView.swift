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
            // plugin.state.updated events (start, crash, restart, and list
            // changes) bump the revision; refetch the light list.
            .onChange(of: environment.pluginStateRevision(for: serverId)) { _, _ in
                Task { await refreshList() }
            }
            // A codevisor://install-plugin deeplink staged a source before
            // routing here: consume it into the standard discover→consent
            // install sheet.
            .onChange(of: SettingsRouter.shared.pendingPluginInstallSource, initial: true) {
                _, source in
                guard let source else { return }
                SettingsRouter.shared.pendingPluginInstallSource = nil
                activeSheet = .install(initialSource: source)
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
                            // through the existing consent flow with the
                            // entry's repo as the source.
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

    // Custom empty state (not ContentUnavailableView): it packs its actions
    // right against the title.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No Plugins Installed")
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Button("Browse Plugins") { activeSheet = .browse }
                    .buttonStyle(.borderedProminent)
                    .settingsActionTint(theme)
                Button("Install Plugin…") { activeSheet = .install(initialSource: nil) }
                    .settingsActionTint(theme)
            }
            .padding(.top, 8)
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
                HStack(spacing: 10) {
                    Button {
                        activeSheet = .browse
                    } label: {
                        Label("Browse Plugins…", systemImage: "magnifyingglass")
                    }
                    .settingsActionTint(theme)
                    Button {
                        activeSheet = .install(initialSource: nil)
                    } label: {
                        Label("Install Plugin…", systemImage: "plus")
                    }
                    .settingsActionTint(theme)
                }
            } header: {
                Text("Installed")
            }
        }
        .settingsPaneFormStyle(theme)
        .disabled(isMutating)
    }

    private func pluginRow(_ plugin: ServerPluginSummary) -> some View {
        HStack(spacing: 10) {
            PluginIconView(
                pluginId: plugin.id,
                iconPath: plugin.iconPath,
                client: client,
                cacheNamespace: serverId,
                fallbackSystemName: "puzzlepiece"
            )
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
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
/// A registry selection arrives as `initialSource` (the entry's repo) and
/// auto-discovers — skipping the typing, never the consent.
private struct PluginInstallSheet: View {
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
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
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
                // HIG loading state: the default action is replaced by an
                // indeterminate spinner while it runs — never a relabeled,
                // still-tappable-looking button.
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.isSystem ? nil : theme.accent)
                        .padding(.horizontal, 12)
                } else if discovery == nil {
                    Button("Find Plugin") {
                        Task { await find() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Install") {
                        Task { await runInstall() }
                    }
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

    /// The consent stage, structured like the registry detail page: what the
    /// plugin is, what it adds, and — verbatim — what it will run.
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
        .listRowBackground(themedFormRowBackground)
        Section("Details") {
            LabeledContent("Source", value: source.trimmingCharacters(in: .whitespaces))
            if !discovery.panes.isEmpty {
                LabeledContent(
                    "Panes",
                    value: discovery.panes.map(\.title).joined(separator: ", ")
                )
            }
        }
        .listRowBackground(themedFormRowBackground)
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
            .listRowBackground(themedFormRowBackground)
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
            Text("Installing runs these commands on this machine.")
        }
        .listRowBackground(themedFormRowBackground)
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
