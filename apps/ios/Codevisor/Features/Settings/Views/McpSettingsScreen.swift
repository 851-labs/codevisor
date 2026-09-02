import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - MCPs

/// The MCP screen: a machine list that pushes each machine's MCP servers;
/// the toggle means "available on this machine" and writes the per-machine
/// overlay.
struct McpSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    List {
      MachineListSection(badge: badge) { machine in
        McpMachineRows(machine: machine)
      }
    }
    .navigationTitle("MCPs")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
    if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
      return .attention("Unreachable")
    }
    guard let key = environment.machines.syncKey(forMachineId: machine.id),
      let rows = McpFleet.readiness(environment.configSync)[key]
    else { return .syncing }
    if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
    if rows.contains(where: { $0.state == "connecting" }) { return .syncing }
    return .synced
  }
}

/// One machine's MCP servers with machine-effective enable state.
private struct McpMachineRows: View {
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  @State private var servers: [ServerMcpServer] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machine.id)
  }

  var body: some View {
    // Overlay flips re-derive every row's effective state immediately.
    let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
    Group {
      if isLoading, servers.isEmpty {
        HStack {
          Spacer(); ProgressView(); Spacer()
        }
      } else if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
      } else if servers.isEmpty {
        Text("No MCP servers added yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(servers, id: \.id) { server in
          serverRow(server)
        }
      }
    }
    .task(id: machine.id) {
      isLoading = true
      await load()
    }
  }

  private func machineDisabled(_ server: ServerMcpServer) -> Bool {
    guard let key = environment.machines.syncKey(forMachineId: machine.id) else { return false }
    return McpFleet.isDisabled(environment.configSync, machineId: key, name: server.name)
  }

  private func serverRow(_ server: ServerMcpServer) -> some View {
    let effectiveEnabled = server.enabled && !machineDisabled(server)
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(server.name)
          if server.kind == "browserUse" || server.kind == "computerUse" {
            Text("Built-in")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.15), in: Capsule())
          }
        }
        Text(effectiveEnabled ? server.connectionState : "Disabled on this machine")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle(
        "Enable \(server.name)",
        isOn: Binding(
          get: { effectiveEnabled },
          set: { enabled in Task { await setEnabled(server, enabled: enabled) } }
        )
      )
      .labelsHidden()
    }
    .contextMenu {
      if server.canRemove != false {
        Button(role: .destructive) {
          Task {
            try? await client.removeMcpServer(id: server.id)
            await load()
          }
        } label: {
          Label("Remove…", systemImage: "trash")
        }
      }
    }
  }

  /// The toggle's one meaning: available on THIS machine. Off writes the
  /// per-machine overlay only. On clears the overlay — and if the fleet
  /// definition itself was off, re-enables it for the fleet.
  private func setEnabled(_ server: ServerMcpServer, enabled: Bool) async {
    guard let key = environment.machines.syncKey(forMachineId: machine.id) else {
      errorMessage = "This machine hasn't reported its identity yet."
      return
    }
    McpFleet.setDisabled(
      environment.configSync,
      machineId: key,
      name: server.name,
      disabled: !enabled
    )
    if enabled, !server.enabled {
      _ = try? await client.setMcpServerEnabled(id: server.id, enabled: true)
      await load()
    }
  }

  private func load() async {
    do {
      servers = try await client.listMcpServers()
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
    isLoading = false
  }
}
