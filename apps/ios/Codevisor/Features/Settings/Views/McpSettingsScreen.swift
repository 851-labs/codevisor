import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = McpGlobalModel()
  @State private var pendingRemoval: McpFleetEntry?
  @State private var editing: McpEditorTarget?
  @State private var actionError: String?

  private struct McpEditorTarget: Identifiable {
    let entry: McpFleetEntry?
    var server: ServerMcpServer? { entry?.representative }
    var id: String { entry?.name ?? "new" }
  }

  private var authoringMachineId: String {
    environment.machines.selectedMachineId
  }
  @Environment(\.openURL) private var openURL

  var body: some View {
    List {
      Section("Built-in Tools") {
        fleetSection(builtIn: true)
      }
      Section("MCP Servers") {
        fleetSection(builtIn: false)
      }
    }
    .navigationTitle("MCPs")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          editing = McpEditorTarget(entry: nil)
        } label: {
          Label("Add MCP Server", systemImage: "plus")
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
    .alert(
      "Remove \(pendingRemoval?.name ?? "MCP server")?",
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
      "Couldn’t update MCP servers",
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

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(
      model: model,
      builtIn: builtIn,
      onDetails: { _ in },
      onEdit: { entry in editing = McpEditorTarget(entry: entry) },
      onRemove: { pendingRemoval = $0 },
      onConnect: { entry, machineId in
        Task { await beginOAuth(entry: entry, machineId: machineId) }
      },
      icon: { entry in McpEntryIcon(entry: entry) },
      machineExtras: { _, _ in EmptyView() })
  }

  private var mcpStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.mcpStateRevision(for: $0.id) }
  }

  private func beginOAuth(entry: McpFleetEntry, machineId: String) async {
    guard let serverId = entry.idByMachine[machineId] else { return }
    await beginOAuth(serverId: serverId, machineId: machineId)
  }

  private func beginOAuth(serverId: String, machineId: String) async {
    do {
      let flow = try await environment.machines.client(for: machineId).startMcpOAuth(id: serverId)
      if let url = URL(string: flow.authorizationUrl) { openURL(url) }
      actionError = nil
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
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
      let created = try await environment.machines.client(for: authoringMachineId)
        .createMcpServer(values.createBody)
      await model.load(in: environment)
      if created.authType == "oauth" {
        await beginOAuth(serverId: created.id, machineId: authoringMachineId)
      }
    }
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
