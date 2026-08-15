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
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
