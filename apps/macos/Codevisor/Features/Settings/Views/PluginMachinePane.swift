import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// One machine's plugins, rendered on its page: live
/// runtime-state chips, restart/uninstall actions, and the two-stage
/// install sheet that shows the exact commands a plugin will run before
/// anything executes.
struct PluginMachinePane: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let machine: CodevisorMachine
  @State private var plugins: [ServerPluginSummary]?
  @State private var updates: [String: ServerPluginUpdateStatus] = [:]
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var actionError: String?
  @State private var activeSheet: PluginsSheet?
  @State private var pluginPendingRemoval: ServerPluginSummary?
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

  /// The machine whose plugins this pane manages.
  private var serverId: String { machine.id }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  var body: some View {
    content
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
        guard let source, machine.isLocal else { return }
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
        .settingsActionTint(theme)
        Button("Cancel", role: .cancel) { pluginPendingRestore = nil }
          .settingsActionTint(theme)
      } message: {
        Text(
          "This restores the verified pre-update code and data. The current version becomes the next restore point."
        )
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

  private var content: some View {
    Section {
      if isLoading, plugins == nil {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else if let errorMessage, plugins == nil {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      } else {
        if let actionError {
          Label(actionError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(theme.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
            .font(.callout)
        }
        if (plugins ?? []).isEmpty {
          Text("No plugins installed on this machine.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(plugins ?? []) { plugin in
            pluginRow(plugin)
          }
        }
      }
    } footer: {
      // The actions arrive with the list: nothing to install into
      // while the list is still loading or the machine is unreachable.
      if plugins != nil {
        SettingsListActions {
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
      }
    }
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        if updates[plugin.id]?.state == .available {
          Button("Update…") { prepareUpdate(plugin) }
          Divider()
        }
        if updates[plugin.id]?.state == .sourceUnknown {
          Button("Reinstall to Enable Updates…") {
            activeSheet = .install(initialSource: nil)
          }
        }
        if plugin.canRestore == true {
          Button("Restore Previous Version…") { pluginPendingRestore = plugin }
        }
        Button(plugin.isEnabled ? "Disable" : "Enable") {
          setEnabled(plugin, enabled: !plugin.isEnabled)
        }
        if plugin.isEnabled {
          Button("Restart") {
            Task {
              _ = try? await mutate {
                try await client.restartPlugin(pluginId: plugin.id)
              }
              await refreshList()
            }
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
    .accessibilityLabel(accessibilityLabel(for: plugin))
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

  private func setEnabled(_ plugin: ServerPluginSummary, enabled: Bool) {
    Task {
      _ = try? await mutate {
        try await client.setPluginEnabled(pluginId: plugin.id, enabled: enabled)
      }
      await refreshList()
    }
  }

  private func updateChip(_ update: ServerPluginUpdateStatus) -> some View {
    Text(updateTitle(update))
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
      )
      .foregroundStyle(updateStyle(update.state))
      .help(update.reason ?? updateTitle(update))
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
    case .current: AnyShapeStyle(theme.statusOK)
    case .available: AnyShapeStyle(theme.accent)
    case .incompatible, .checkFailed: AnyShapeStyle(theme.statusWarn)
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
        // Plugin listing remains useful against an older server or
        // during a transient registry outage.
        updates = [:]
      }
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

private func pluginRuntimeState(_ plugin: ServerPluginSummary) -> String {
  plugin.isEnabled ? plugin.state : "disabled"
}
