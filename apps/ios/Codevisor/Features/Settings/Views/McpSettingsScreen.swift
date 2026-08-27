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
                    }
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text("MCP servers are shared by your whole fleet.")
                }
            }
            machinesSection
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: serverId) {
            isLoading = true
            await load()
        }
    }

    /// One disclosure per machine: sync badge on the row, that machine's
    /// MCP reports and per-machine toggles inside. Hidden for
    /// single-machine fleets.
    @ViewBuilder
    private var machinesSection: some View {
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let readiness = McpFleet.readiness(environment.configSync)
        if environment.machines.allMachines.count > 1, !readiness.isEmpty {
            Section("On Your Machines") {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    let rows = readiness[machineId] ?? []
                    DisclosureGroup {
                        ForEach(rows) { entry in
                            readinessRow(machineId: machineId, entry: entry)
                        }
                    } label: {
                        HStack {
                            Text(machineName(machineId))
                            Spacer(minLength: 12)
                            badge(rows).view
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func machineName(_ machineId: String) -> String {
        environment.machines.fleetName(forSyncKey: machineId)
    }

    private func badge(_ rows: [McpFleet.MachineReadiness]) -> MachineSyncBadge {
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "connecting" }) { return .syncing }
        return .synced
    }

    private func readinessRow(machineId: String, entry: McpFleet.MachineReadiness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.reason ?? entry.state)
                    .font(.footnote)
                    .foregroundStyle(
                        entry.state == "blocked" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Toggle(
                "Enable \(entry.name) on \(machineName(machineId))",
                isOn: Binding(
                    get: {
                        !McpFleet.isDisabled(
                            environment.configSync, machineId: machineId, name: entry.name)
                    },
                    set: { enabled in
                        McpFleet.setDisabled(
                            environment.configSync,
                            machineId: machineId,
                            name: entry.name,
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
