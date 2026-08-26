import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - MCPs

struct McpSettingsScreen: View {
    let client: any CodevisorServerClienting
    @Environment(AppEnvironment.self) private var environment
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
                Section("MCP Servers") {
                    ForEach(servers, id: \.id) { server in
                        serverRow(server)
                    }
                }
            }
            machinesSection
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Phase 18: what each MCP looks like on every machine that reported
    /// (the "mcp-readiness" namespace), with the per-machine disable toggle.
    /// Hidden for single-machine fleets — the main list tells that story.
    @ViewBuilder
    private var machinesSection: some View {
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let readiness = McpFleet.readiness(environment.configSync)
        if environment.machines.machines.count > 1, !readiness.isEmpty {
            Section {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    DisclosureGroup(machineName(machineId)) {
                        ForEach(readiness[machineId] ?? []) { entry in
                            readinessRow(machineId: machineId, entry: entry)
                        }
                    }
                }
            } header: {
                Text("On Your Machines")
            } footer: {
                Text("Turning one off disables it on that machine only.")
            }
        }
    }

    private func machineName(_ machineId: String) -> String {
        environment.machines.fleetMachineName(for: machineId) ?? machineId
    }

    private func readinessRow(machineId: String, entry: McpFleet.MachineReadiness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.reason ?? entry.state)
                    .font(.footnote)
                    .foregroundStyle(entry.state == "blocked" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
