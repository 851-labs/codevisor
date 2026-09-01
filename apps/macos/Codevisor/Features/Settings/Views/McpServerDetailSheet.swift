import CodevisorCore
import SwiftUI
import CodevisorUI

struct McpServerDetailSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.settingsMachineId) private var settingsMachineId
    let server: ServerMcpServer
    let didChange: () async -> Void
    @State private var tools: [ServerMcpTool] = []
    @State private var isLoadingTools = false
    @State private var errorMessage: String?
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: server.connectionState == "connected" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        server.connectionState == "connected"
                            ? AnyShapeStyle(theme.statusOK)
                            : AnyShapeStyle(.secondary)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.headline)
                    Text(connectionStateLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Form {
                Section("Connection") {
                    if server.kind == "browserUse" || server.kind == "computerUse" {
                        LabeledContent("Provider", value: "Codevisor built-in")
                    } else {
                        LabeledContent("Transport", value: server.transport == "http" ? "HTTP" : "Local command")
                    }
                    if let url = server.url {
                        LabeledContent("Server URL") {
                            Text(url).textSelection(.enabled)
                        }
                    }
                    if let command = server.command {
                        LabeledContent("Command") {
                            Text(([command] + server.args).joined(separator: " "))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if server.transport == "http" {
                        LabeledContent("Authorization", value: authorizationLabel)
                    }
                    if server.transport == "http", let count = server.headerNames?.count, count > 0 {
                        LabeledContent("HTTP Headers", value: "\(count) configured")
                    }
                    if server.transport == "stdio", let count = server.environmentNames?.count, count > 0 {
                        LabeledContent(
                            "Environment Variables",
                            value: "\(count) variable\(count == 1 ? "" : "s")"
                        )
                    }
                    if server.transport == "http", server.authType == "oauth" {
                        Text("Authorization renews automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(themedFormRowBackground)
                Section("Tools") {
                    if isLoadingTools {
                        ProgressView().controlSize(.small)
                    } else if tools.isEmpty {
                        Text("No tools available").foregroundStyle(.secondary)
                    } else {
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title ?? tool.name)
                                if let description = tool.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(themedFormRowBackground)
                if let errorMessage { Text(errorMessage).foregroundStyle(theme.statusError) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if server.canRemove != false {
                    Button("Remove…", role: .destructive) { confirmingRemoval = true }
                        .settingsActionTint(theme)
                }
                if server.authType == "oauth" && server.connectionState == "connected" {
                    Button("Sign Out") { Task { await disconnect() } }
                        .settingsActionTint(theme)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 540, height: 470)
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedSurface(.sheet)
        .task { await loadTools() }
        .confirmationDialog(
            "Remove \(server.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove MCP Server", role: .destructive) { Task { await remove() } }
                .settingsActionTint(theme)
            Button("Cancel", role: .cancel) {}
                .settingsActionTint(theme)
        } message: {
            Text("This removes its configuration and saved authorization from Codevisor.")
        }
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: settingsMachineId ?? environment.defaultComposerServerId)
    }

    private var connectionStateLabel: String {
        switch server.connectionState {
        case "connected": return "Connected · \(server.toolCount) tool\(server.toolCount == 1 ? "" : "s")"
        case "connecting": return "Connecting…"
        case "needsSetup": return server.detail ?? "Browser setup required"
        case "unavailable": return server.detail ?? "Unavailable on this machine"
        case "needsAuthorization": return "Authorization required"
        case "expired": return "Sign-in expired"
        case "error": return server.detail ?? "Connection failed"
        default: return server.enabled ? "Not connected" : "Disabled"
        }
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private var authorizationLabel: String {
        switch server.authType {
        case "oauth": return "OAuth"
        case "bearer": return "Bearer token"
        default: return "None"
        }
    }

    private func loadTools() async {
        isLoadingTools = true
        defer { isLoadingTools = false }
        do { tools = try await client.listMcpTools(id: server.id) } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func remove() async {
        do {
            try await client.removeMcpServer(id: server.id)
            await didChange()
            dismiss()
        } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
    }

    private func disconnect() async {
        do {
            _ = try await client.disconnectMcpOAuth(id: server.id)
            await didChange()
            dismiss()
        } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
    }
}
