import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = PluginGlobalModel()
  @State private var activeSheet: PluginsRootSheet?
  @State private var pendingRemoval: PluginFleetEntry?
  @State private var pendingRestore: PluginFleetEntry?
  @State private var pendingUnlink: PluginUnlinkRequest?
  @State private var reporting: PluginFleetEntry?
  @State private var actionError: String?

  private struct PluginUnlinkRequest: Identifiable {
    let entry: PluginFleetEntry
    let machineId: String
    var id: String { "\(machineId)|\(entry.id)" }
  }

  private enum PluginsRootSheet: Identifiable {
    case install(initialSource: String?)
    case browse
    case update(ServerPluginUpdatePlan, machineId: String)
    var id: String {
      switch self {
      case .install: "install"
      case .browse: "browse"
      case .update(let plan, _): "update:\(plan.planId)"
      }
    }
  }

  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      PluginFleetSection(
        model: model,
        actions: PluginFleetActions(
          update: { entry in Task { await prepareUpdate(entry) } },
          restore: { pendingRestore = $0 },
          uninstall: { pendingRemoval = $0 },
          unlink: { entry, machineId in
            pendingUnlink = PluginUnlinkRequest(entry: entry, machineId: machineId)
          },
          report: { reporting = $0 },
          reveal: { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          })
      ) {
        SettingsListActions(message: actionError) {
          Button {
            activeSheet = .browse
          } label: {
            Label("Browse Plugins…", systemImage: "magnifyingglass")
          }
          Button {
            activeSheet = .install(initialSource: nil)
          } label: {
            Label("Install Plugin…", systemImage: "plus")
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .onChange(of: pluginStateRevisions) { _, _ in model.scheduleReload(in: environment) }
    .onChange(of: SettingsRouter.shared.pendingPluginInstallSource, initial: true) { _, source in
      guard let source else { return }
      SettingsRouter.shared.pendingPluginInstallSource = nil
      activeSheet = .install(initialSource: source)
    }
    .sheet(item: $activeSheet) { sheet in
      sheetContent(sheet)
    }
    .sheet(item: $reporting) { entry in
      PluginReportSheet(pluginId: entry.id, name: entry.name)
        .environment(environment)
    }
    .confirmationDialog(
      "Uninstall \(pendingRemoval?.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Uninstall Plugin", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await uninstall(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text(uninstallMessage)
    }
    .confirmationDialog(
      "Remove the link to \(pendingUnlink?.entry.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Link", role: .destructive) {
        guard let request = pendingUnlink else { return }
        Task { await unlink(request) }
      }
      Button("Cancel", role: .cancel) { pendingUnlink = nil }
    } message: {
      Text("Your checkout isn't deleted.")
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
  }

  private var pluginStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.pluginStateRevision(for: $0.id) }
  }

  private var uninstallMessage: String {
    let machines = environment.machines.allMachines.count
    let scope =
      machines > 1 ? "Removes it from all \(machines) machines." : "Removes it from this machine."
    let panes = pendingRemoval?.openPaneCount ?? 0
    guard panes > 0 else { return scope }
    return "\(scope) \(panes) open pane\(panes == 1 ? "" : "s") will close."
  }

  @ViewBuilder
  private func sheetContent(_ sheet: PluginsRootSheet) -> some View {
    switch sheet {
    case .install(let initialSource):
      PluginInstallSheet(
        initialSource: initialSource,
        discover: { try await localClient.discoverRemotePlugin(source: $0) },
        onInstall: { source in
          do {
            _ = try await localClient.importRemotePlugin(source: source)
            actionError = nil
            await model.load(in: environment)
          } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
          }
        })
    case .browse:
      PluginRegistryBrowseSheet(
        fetchRegistry: { try await localClient.fetchPluginRegistry(query: nil) },
        installedIds: Set(model.entries(environment.configSync).map(\.id)),
        onInstall: { entry in
          activeSheet = .install(initialSource: entry.repo)
        })
    case .update(let plan, let machineId):
      PluginUpdateSheet(
        plan: plan,
        onApply: {
          do {
            _ = try await environment.machines.client(for: machineId)
              .applyPluginUpdate(pluginId: plan.pluginId, planId: plan.planId)
            actionError = nil
            await model.load(in: environment)
          } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
          }
        })
    }
  }

  private func prepareUpdate(_ entry: PluginFleetEntry) async {
    guard let machineId = entry.sourceMachineId else { return }
    do {
      let plan = try await environment.machines.client(for: machineId)
        .preparePluginUpdate(pluginId: entry.id)
      actionError = nil
      activeSheet = .update(plan, machineId: machineId)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func uninstall(_ entry: PluginFleetEntry) async {
    pendingRemoval = nil
    PluginFleet.remove(entry.id, in: environment.configSync)
    await model.load(in: environment)
  }

  private func unlink(_ request: PluginUnlinkRequest) async {
    pendingUnlink = nil
    do {
      _ = try await environment.machines.client(for: request.machineId)
        .unlinkPlugin(pluginId: request.entry.id)
      actionError = nil
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func restore(_ entry: PluginFleetEntry) async {
    pendingRestore = nil
    guard let machineId = entry.sourceMachineId else { return }
    do {
      _ = try await environment.machines.client(for: machineId).restorePlugin(pluginId: entry.id)
      actionError = nil
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

#Preview("Plugins Settings") {
  PluginsSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 560, height: 460)
}
