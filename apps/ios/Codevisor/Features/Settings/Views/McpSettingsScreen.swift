import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - MCPs

struct McpSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State var serverId: String

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }
    @State private var servers: [ServerMcpServer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if servers.isEmpty {
                Text("No MCP servers managed by Codevisor yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(servers, id: \.id) { server in
                        serverRow(server)
                        machineStatusRows(server)
                    }
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text("MCP servers are shared by your whole fleet.")
                }
            }
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: serverId) {
            isLoading = true
            await load()
        }
    }

    /// The per-item machine reality (Phase 27a): each machine's report of
    /// this server, with the per-machine disable toggle inline. Hidden for
    /// single-machine fleets.
    @ViewBuilder
    private func machineStatusRows(_ server: ServerMcpServer) -> some View {
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let rows = McpFleet.readinessByServer(environment.configSync)[server.name] ?? []
        if environment.machines.machines.count > 1, !rows.isEmpty {
            DisclosureGroup("On your machines") {
                ForEach(rows) { row in
                    machineRow(server: server.name, row: row)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func machineName(_ machineId: String) -> String {
        environment.machines.fleetMachineName(for: machineId) ?? machineId
    }

    private func machineRow(server: String, row: McpFleet.MachineStatus) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(machineName(row.machineId))
                Text(row.reason ?? row.state)
                    .font(.footnote)
                    .foregroundStyle(
                        row.state == "blocked" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Toggle(
                "Enable \(server) on \(machineName(row.machineId))",
                isOn: Binding(
                    get: {
                        !McpFleet.isDisabled(
                            environment.configSync, machineId: row.machineId, name: server)
                    },
                    set: { enabled in
                        McpFleet.setDisabled(
                            environment.configSync,
                            machineId: row.machineId,
                            name: server,
                            disabled: !enabled
                        )
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func serverRow(_ server: ServerMcpServer) -> some View {
        HStack {
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
                Text(server.connectionState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(server.name)",
                isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setMcpServerEnabled(
                                id: server.id, enabled: enabled
                            )
                            await load()
                        }
                    }
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
