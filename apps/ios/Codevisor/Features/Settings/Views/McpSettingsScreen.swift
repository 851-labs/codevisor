import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = McpGlobalModel()
  @State private var pendingRemoval: McpFleetEntry?
  @State private var editing: McpEditorTarget?
  @State private var details: McpDetailTarget?
  @State private var showingCatalog = false
  @State private var actionError: String?

  private struct McpEditorTarget: Identifiable {
    let entry: McpFleetEntry?
    var server: ServerMcpServer? { entry?.representative }
    var id: String { entry?.name ?? "new" }
  }

  private struct McpDetailTarget: Identifiable {
    let server: ServerMcpServer
    let machineId: String
    var id: String { "\(server.id)|\(machineId)" }
  }

  private var authoringMachineId: String {
    let selected = environment.machines.selectedMachineId
    guard !supportsPlugins(selected) else { return selected }
    return environment.machines.allMachines.map(\.id).first(where: supportsPlugins) ?? selected
  }

  var body: some View {
    List {
      Section("Built-in Tools") {
        fleetSection(builtIn: true)
      }
      Section("Plugins") {
        fleetSection(builtIn: false)
      }
      Section {
        NavigationLink("Blocked Publishers") { PluginBlockedPublishersView() }
      }
    }
    .navigationTitle("Plugins")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if supportsCatalog {
            Button("Browse Plugins…") { showingCatalog = true }
          }
          Button("Add MCP…") { editing = McpEditorTarget(entry: nil) }
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .onChange(of: mcpStateRevisions) { _, _ in model.scheduleReload(in: environment) }
    .onChange(of: environment.configSync.revisionsByNamespace["mcp-readiness"]) { _, _ in
      model.settle(in: environment)
    }
    .sheet(item: $editing) { target in
      McpServerEditor(
        initialServer: target.server, machineId: editorMachineId(for: target.entry)
      ) { values in
        try await save(values, for: target.entry)
      }
      .environment(environment)
    }
    .sheet(isPresented: $showingCatalog) {
      PluginCatalogScreen(
        client: environment.machines.client(for: authoringMachineId),
        installedCatalogIds: model.installedCatalogIds,
        onInstalled: { await didAdd($0, on: authoringMachineId) })
    }
    .sheet(item: $details) { target in
      McpServerDetailScreen(
        server: target.server, client: environment.machines.client(for: target.machineId))
    }
    .alert(
      "Remove \(pendingRemoval?.name ?? "plugin")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    ) {
      Button("Remove", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await remove(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    }
    .alert(
      "Couldn’t update plugins",
      isPresented: Binding(
        get: { (actionError ?? model.actionError ?? model.connectError) != nil },
        set: { if !$0 { dismissErrors() } })
    ) {
      Button("OK", role: .cancel) { dismissErrors() }
    } message: {
      Text(actionError ?? model.actionError ?? model.connectError ?? "")
    }
  }

  private func dismissErrors() {
    actionError = nil
    model.actionError = nil
    model.connectError = nil
  }

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(
      model: model,
      builtIn: builtIn,
      onDetails: showDetails,
      onEdit: { entry in editing = McpEditorTarget(entry: entry) },
      onRemove: { pendingRemoval = $0 },
      onConnect: { entry, machineId in
        Task { await beginOAuth(entry: entry, machineId: machineId) }
      },
      icon: { entry in McpEntryIcon(entry: entry) },
      machineExtras: { _, _ in EmptyView() })
  }

  private var supportsCatalog: Bool {
    supportsPlugins(authoringMachineId)
  }

  private func supportsPlugins(_ machineId: String) -> Bool {
    environment.machines.statusByMachineId[machineId]?.supportsPlugins == true
  }

  private func showDetails(_ entry: McpFleetEntry) {
    guard let machineId = entry.machineId(preferring: authoringMachineId),
      let server = entry.server(on: machineId)
    else { return }
    details = McpDetailTarget(server: server, machineId: machineId)
  }

  private func didAdd(_ created: ServerMcpServer, on machineId: String) async {
    await model.load(in: environment)
    guard created.awaitsAuthorization else { return }

    await beginOAuth(serverId: created.id, machineId: machineId)
  }

  private var mcpStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.mcpStateRevision(for: $0.id) }
  }

  private func beginOAuth(entry: McpFleetEntry, machineId: String) async {
    guard let serverId = entry.idByMachine[machineId] else { return }
    await beginOAuth(serverId: serverId, machineId: machineId)
  }

  private func beginOAuth(serverId: String, machineId: String) async {
    await model.connect(serverId: serverId, on: machineId, in: environment)
  }

  private func editorMachineId(for entry: McpFleetEntry?) -> String {
    entry?.machineId(preferring: authoringMachineId) ?? authoringMachineId
  }

  private func save(_ values: McpFormValues, for entry: McpFleetEntry?) async throws {
    if let entry {
      guard let machineId = entry.machineId(preferring: authoringMachineId),
        let serverId = entry.idByMachine[machineId]
      else { return }
      let updated = try await environment.machines.client(for: machineId)
        .updateMcpServer(id: serverId, request: values.updateBody)
      await model.load(in: environment)
      if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
        await beginOAuth(serverId: serverId, machineId: machineId)
      }
    } else {
      try await recordConsent(for: values)
      let created = try await environment.machines.client(for: authoringMachineId)
        .createMcpServer(values.createBody)
      await didAdd(created, on: authoringMachineId)
    }
  }

  private func recordConsent(for values: McpFormValues) async throws {
    let subject = PluginModerationSubject(custom: values.customLocation, name: values.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }

  private func remove(_ entry: McpFleetEntry) async {
    pendingRemoval = nil
    guard let machineId = entry.machineId(preferring: environment.machines.selectedMachineId),
      let serverId = entry.idByMachine[machineId]
    else { return }
    do {
      try await environment.machines.client(for: machineId).removeMcpServer(id: serverId)
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
