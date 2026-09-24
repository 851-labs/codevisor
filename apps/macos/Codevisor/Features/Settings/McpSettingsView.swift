import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

/// The MCP pane: built-in tools and managed servers as the fleet wants them,
/// each with its machines nested beneath. The server's row carries the fleet
/// wish and the one fleet-wide act (authorizing); a machine row carries what
/// is genuinely machine-specific — availability here, this Mac's Computer Use
/// permissions, that machine's browser choice.
struct McpSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var model = McpGlobalModel()
  /// This Mac's TCC probes. They describe THIS machine only; a remote
  /// machine's permissions are its own server's story, and its row says so.
  @State private var permissions = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live)
  @State private var showingAdd = false
  @State private var editing: McpFleetEntry?
  @State private var details: McpFleetEntry?
  @State private var pendingRemoval: McpFleetEntry?
  @State private var showsOtherServers = false
  @State private var actionError: String?

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
        Text("MCP Servers")
      } footer: {
        SettingsListActions(message: actionError ?? model.actionError) {
          Button {
            showingAdd = true
          } label: {
            Label("Add MCP Server…", systemImage: "plus")
          }
          .settingsActionTint(theme)
        }
      }
      McpOtherServersSection(isExpanded: $showsOtherServers)
    }
    .settingsPaneFormStyle(theme)
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .onChange(of: mcpStateRevisions) { _, _ in model.scheduleReload(in: environment) }
    .sheet(isPresented: $showingAdd) {
      McpServerEditorSheet(initialServer: nil) { values in
        let created = try await localClient.createMcpServer(values.createBody)
        await model.load(in: environment)
        if created.authType == "oauth" {
          await beginOAuth(serverId: created.id, machineId: CodevisorMachine.local.id)
        }
      }
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
          await beginOAuth(serverId: serverId, machineId: machineId)
        }
      }
    }
    .sheet(item: $details) { entry in
      McpServerDetailSheet(server: entry.representative) {
        await model.load(in: environment)
      }
      .environment(environment)
      .environment(\.settingsMachineId, entry.machineId(preferring: CodevisorMachine.local.id) ?? "")
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "MCP server")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove MCP Server", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await remove(entry) }
      }
      .settingsActionTint(theme)
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
        .settingsActionTint(theme)
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(
      model: model,
      builtIn: builtIn,
      onDetails: { details = $0 },
      onEdit: { editing = $0 },
      onRemove: { pendingRemoval = $0 },
      onConnect: { entry, machineId in
        guard let serverId = entry.idByMachine[machineId] else { return }
        Task { await beginOAuth(serverId: serverId, machineId: machineId) }
      },
      toggleDisabledReason: { entry, machineId in
        // Only this Mac's grants are knowable here; another machine's
        // Computer Use reports its own condition through readiness.
        guard entry.kind == "computerUse", machineId == CodevisorMachine.local.id,
          !permissions.allGranted
        else { return nil }
        return "Computer Use needs Accessibility and Screen Recording on this Mac."
      },
      icon: { entry in McpEntryIcon(entry: entry) },
      machineExtras: { entry, machineId in
        // Computer Use depends on TCC grants held by the Codevisor app on
        // that machine. They can only be read — and only here — so the rows
        // appear under this Mac and nowhere else.
        if entry.kind == "computerUse", machineId == CodevisorMachine.local.id {
          ComputerUsePermissionRowsView(model: permissions, embedded: true)
            .padding(.leading, FleetRowMetrics.iconColumnWidth + 8)
            .onChange(of: permissions.allGranted) { _, granted in
              // Revoked underneath a running Computer Use: switch it off
              // here so the row never claims to work when it can't.
              guard !granted, entry.enabledByMachine[machineId] == true else { return }
              Task {
                await model.setEnabled(
                  entry, on: machineId, enabled: false, in: environment)
              }
            }
        }
      })
  }

  private var mcpStateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.mcpStateRevision(for: $0.id) }
  }

  /// Authorizing is fleet-wide: the material replicates under a refresh
  /// owner, and every other machine adopts it. Polling keeps the row honest
  /// until the machine that ran the flow reports connected.
  private func beginOAuth(serverId: String, machineId: String) async {
    let client = environment.machines.client(for: machineId)
    do {
      let flow = try await client.startMcpOAuth(id: serverId)
      guard let url = URL(string: flow.authorizationUrl) else { return }
      NSWorkspace.shared.open(url)
      actionError = nil
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
      return
    }
    for _ in 0..<60 {
      try? await Task.sleep(for: .seconds(2))
      await model.load(in: environment)
      if let entry = model.entries.first(where: { $0.idByMachine[machineId] == serverId }),
        entry.representative.connectionState == "connected"
      {
        break
      }
    }
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

#Preview("MCP Settings") {
  McpSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 560, height: 460)
}
