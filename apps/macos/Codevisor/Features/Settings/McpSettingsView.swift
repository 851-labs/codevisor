import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct McpSettingsView: View {
  private struct McpDetailTarget: Identifiable {
    let entryName: String
    let machineId: String
    var id: String { "\(entryName)|\(machineId)" }
  }

  @Environment(AppEnvironment.self) private var environment
  @State private var permissions = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live)
  @State private var showingCustom = false
  @State private var showingBlockedPublishers = false
  @State private var editing: McpFleetEntry?
  @State private var details: McpDetailTarget?
  @State private var pendingRemoval: McpFleetEntry?
  @State private var showsOtherServers = false
  @State private var actionError: String?

  let plugins: PluginSettingsModel

  private var model: McpGlobalModel { plugins.fleet }

  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      Section("Built-in Tools") {
        fleetSection(builtIn: true)
      }
      Section {
        fleetSection(builtIn: false)
      } header: {
        Text("Plugins")
      } footer: {
        SettingsListActions(message: actionError ?? model.actionError) {
          Button("Blocked Publishers…") { showingBlockedPublishers = true }
          PluginAddMenu(
            canBrowse: supportsCatalog,
            onBrowse: { SettingsRouter.shared.panePath.append(.pluginCatalog) },
            onAddCustom: { showingCustom = true })
        }
      }
      McpOtherServersSection(isExpanded: $showsOtherServers)
    }
    .formStyle(.grouped)
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .onChange(of: mcpStateRevisions) { _, _ in model.scheduleReload(in: environment) }
    .onChange(of: environment.configSync.revisionsByNamespace["mcp-readiness"]) { _, _ in
      model.settle(in: environment)
    }
    .sheet(isPresented: $showingCustom) {
      McpServerEditorSheet(initialServer: nil) { values in
        try await recordConsent(for: values)
        await plugins.didInstall(try await localClient.createMcpServer(values.createBody), in: environment)
      }
    }
    .sheet(isPresented: $showingBlockedPublishers) {
      BlockedPublishersSheet()
    }
    .sheet(item: $editing) { entry in
      McpServerEditorSheet(initialServer: entry.representative) { values in
        guard let machineId = entry.machineId(preferring: CodevisorMachine.local.id),
          let serverId = entry.idByMachine[machineId]
        else { return }
        let updated = try await environment.machines.client(for: machineId)
          .updateMcpServer(id: serverId, request: values.updateBody)
        await model.load(in: environment)
        if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
          await plugins.beginOAuth(serverId: serverId, machineId: machineId, in: environment)
        }
      }
    }
    .sheet(item: $details) { target in
      McpServerDetailSheet(entryName: target.entryName, machineId: target.machineId, model: model)
        .environment(environment)
    }
    .alert(
      "Couldn’t Connect",
      isPresented: Binding(
        get: { model.connectError != nil }, set: { if !$0 { model.connectError = nil } })
    ) {
      Button("OK", role: .cancel) { model.connectError = nil }
    } message: {
      Text(model.connectError ?? "")
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Plugin", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await remove(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(
      model: model,
      builtIn: builtIn,
      onDetails: { entry in
        guard let machineId = entry.machineId(preferring: CodevisorMachine.local.id) else { return }
        details = McpDetailTarget(entryName: entry.name, machineId: machineId)
      },
      onEdit: { editing = $0 },
      onRemove: { pendingRemoval = $0 },
      onConnect: { entry, machineId in
        guard let serverId = entry.idByMachine[machineId] else { return }
        Task { await plugins.beginOAuth(serverId: serverId, machineId: machineId, in: environment) }
      },
      toggleDisabledReason: { entry, machineId in
        guard entry.kind == "computerUse", machineId == CodevisorMachine.local.id,
          !permissions.allGranted
        else { return nil }
        return "Computer Use needs Accessibility and Screen Recording on this Mac."
      },
      icon: { entry in McpEntryIcon(entry: entry) },
      machineExtras: { entry, machineId in
        if entry.kind == "computerUse", machineId == CodevisorMachine.local.id {
          ComputerUsePermissionRowsView(model: permissions, embedded: true)
            .padding(.leading, FleetRowMetrics.iconColumnWidth + 8)
            .onChange(of: permissions.allGranted) { _, granted in
              guard !granted, model.row(for: entry, on: machineId, in: environment)?.isOn == true
              else { return }
              Task { await model.setAvailability(false, of: entry, on: machineId, in: environment) }
            }
        }
      })
  }

  private var supportsCatalog: Bool {
    environment.machines.statusByMachineId[CodevisorMachine.local.id]?.supportsPlugins == true
  }

  private func recordConsent(for values: McpFormValues) async throws {
    let subject = PluginModerationSubject(custom: values.customLocation, name: values.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }

  private var mcpStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.mcpStateRevision(for: $0.id) }
  }

  private func remove(_ entry: McpFleetEntry) async {
    pendingRemoval = nil
    guard let machineId = entry.machineId(preferring: CodevisorMachine.local.id),
      let serverId = entry.idByMachine[machineId]
    else { return }
    do {
      try await environment.machines.client(for: machineId).removeMcpServer(id: serverId)
      actionError = nil
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

#Preview("Plugins Settings") {
  McpSettingsView(plugins: PluginSettingsModel())
    .environment(AppEnvironment.preview())
    .frame(width: 560, height: 460)
}
