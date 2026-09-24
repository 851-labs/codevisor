import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import os

// MARK: - Plugins

/// The Plugins screen: one row per plugin as the fleet wants it, with each
/// machine's condition nested beneath — the same shared section the Mac
/// renders, and the same actions.
struct PluginsSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = PluginGlobalModel()
  @State private var pendingRemoval: PluginFleetEntry?
  @State private var pendingUnlink: PluginUnlinkRequest?
  @State private var reporting: PluginFleetEntry?
  @State private var pendingRestore: PluginFleetEntry?
  @State private var activeSheet: PluginsSheet?
  @State private var actionError: String?

  /// One sheet slot for every flow, so "Install" inside the browse sheet
  /// can swap straight into the install sheet's consent stages.
  private enum PluginsSheet: Identifiable {
    case session(PluginSettingsSession)
    /// An update plan is prepared on one machine and must be applied there.
    case update(ServerPluginUpdatePlan, machineId: String)
    var id: String {
      switch self {
      case .session(let session): "session:\(session.id)"
      case .update(let plan, _): "update:\(plan.planId)"
      }
    }
  }

  /// Removing a link names the machine as well as the plugin: the same
  /// plugin id can be linked on more than one machine.
  private struct PluginUnlinkRequest: Identifiable {
    let entry: PluginFleetEntry
    let machineId: String
    var id: String { "\(machineId)|\(entry.id)" }
  }

  private var availableMachines: [CodevisorMachine] {
    PluginSettingsSession.availableMachines(in: environment.machines)
  }

  var body: some View {
    List {
      if availableMachines.isEmpty {
        ContentUnavailableView {
          Label("No Connected Machines", systemImage: "desktopcomputer")
        } description: {
          Text("Connect a machine to browse and install plugins.")
        }
      } else {
        PluginFleetSection(
          model: model,
          actions: PluginFleetActions(
            update: { entry in Task { await prepareUpdate(entry) } },
            restore: { pendingRestore = $0 },
            uninstall: { pendingRemoval = $0 },
            unlink: { entry, machineId in
              pendingUnlink = PluginUnlinkRequest(entry: entry, machineId: machineId)
            },
            report: { reporting = $0 }))
      }
      Section {
        NavigationLink("Blocked Publishers") { PluginBlockedPublishersView() }
      }
    }
    .navigationTitle("Plugins")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .onChange(of: pluginStateRevisions) { _, _ in model.scheduleReload(in: environment) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Browse Plugins", systemImage: "magnifyingglass") { open(.browse) }
          Button("Add from Repository", systemImage: "link") {
            open(.install(initialSource: nil))
          }
        } label: {
          Label("Add Plugin", systemImage: "plus")
        }
        .disabled(installMachineId == nil)
      }
    }
    .alert(
      "Uninstall \(pendingRemoval?.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    ) {
      Button("Uninstall", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await uninstall(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text(uninstallMessage)
    }
    .sheet(item: $activeSheet) { sheet in
      sheetContent(sheet)
    }
    .confirmationDialog(
      "Restore \(pendingRestore?.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
      titleVisibility: .visible
    ) {
      Button("Restore Previous Version") {
        guard let entry = pendingRestore else { return }
        Task { await restore(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRestore = nil }
    }
    .sheet(item: $reporting) { entry in
      PluginReportSheet(pluginId: entry.id, name: entry.name)
        .environment(environment)
    }
    .alert(
      "Remove the link to \(pendingUnlink?.entry.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } })
    ) {
      Button("Remove Link", role: .destructive) {
        guard let request = pendingUnlink else { return }
        Task { await unlink(request) }
      }
      Button("Cancel", role: .cancel) { pendingUnlink = nil }
    } message: {
      Text("Your checkout isn't deleted.")
    }
    .alert(
      "Couldn’t update plugins",
      isPresented: Binding(
        get: { (actionError ?? model.actionError) != nil },
        set: {
          if !$0 {
            actionError = nil
            model.actionError = nil
          }
        })
    ) {
      Button("OK", role: .cancel) {
        actionError = nil
        model.actionError = nil
      }
    } message: {
      Text(actionError ?? model.actionError ?? "")
    }
  }

  private var uninstallMessage: String {
    let machines = environment.machines.allMachines.count
    return machines > 1
      ? "Removes it from all \(machines) machines."
      : "Removes it from this machine."
  }

  private var pluginStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.pluginStateRevision(for: $0.id) }
  }

  /// Installs land on the machine this device is pointed at when it can take
  /// them, else any reachable one; the fleet entry carries it everywhere.
  private var installMachineId: String? {
    let available = availableMachines.map(\.id)
    let selected = environment.machines.selectedMachineId
    return available.contains(selected) ? selected : available.first
  }

  private func open(_ page: PluginSettingsSession.Page) {
    guard let machineId = installMachineId,
      let session = PluginSettingsSession(
        machines: environment.machines, machineId: machineId, page: page,
        catalog: environment.pluginAccess.catalog)
    else { return }
    activeSheet = .session(session)
  }

  @ViewBuilder
  private func sheetContent(_ sheet: PluginsSheet) -> some View {
    switch sheet {
    case .session(let session):
      switch session.page {
      case .install(let initialSource):
        PluginInstallSheet(
          initialSource: initialSource,
          discover: { try await session.discover(source: $0) },
          onInstall: { source in
            try await session.install(source: source)
            await model.load(in: environment)
          })
      case .browse:
        PluginRegistryBrowseSheet(
          fetchRegistry: { try await session.fetchRegistry() },
          installedPlugins: session.installedPlugins,
          onInstall: { session.showInstall(source: $0.repo) })
      }
    case .update(let plan, let machineId):
      PluginUpdateSheet(
        plan: plan,
        onApply: {
          try await environment.pluginAccess.requireEligible(
            pluginId: plan.pluginId, ageRating: plan.candidate.ageRating)
          _ = try await environment.machines.client(for: machineId)
            .applyPluginUpdate(pluginId: plan.pluginId, planId: plan.planId)
          await model.load(in: environment)
        })
    }
  }

  private func prepareUpdate(_ entry: PluginFleetEntry) async {
    guard let machineId = entry.sourceMachineId else { return }
    do {
      let plan = try await environment.machines.client(for: machineId)
        .preparePluginUpdate(pluginId: entry.id)
      activeSheet = .update(plan, machineId: machineId)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func restore(_ entry: PluginFleetEntry) async {
    pendingRestore = nil
    guard let machineId = entry.sourceMachineId else { return }
    do {
      try await environment.pluginAccess.requireEligible(
        pluginId: entry.id, ageRating: entry.ageRating)
      _ = try await environment.machines.client(for: machineId).restorePlugin(pluginId: entry.id)
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func unlink(_ request: PluginUnlinkRequest) async {
    pendingUnlink = nil
    do {
      _ = try await environment.machines.client(for: request.machineId)
        .unlinkPlugin(pluginId: request.entry.id)
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  /// Uninstall is only ever offered for a shared plugin; a machine-bound
  /// one is removed by Remove Link instead.
  private func uninstall(_ entry: PluginFleetEntry) async {
    pendingRemoval = nil
    PluginFleet.remove(entry.id, in: environment.configSync)
    await model.load(in: environment)
  }
}
