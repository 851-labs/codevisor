import CodevisorCore
import SwiftUI
import CodevisorUI

struct McpServerDetailSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let entryName: String
  let machineId: String
  let model: McpGlobalModel
  @State private var tools: [ServerMcpTool] = []
  @State private var isLoadingTools = false
  @State private var errorMessage: String?
  @State private var confirmingRemoval = false
  @State private var accounts: PluginAccountsModel?
  @State private var subscriptions: PluginSubscriptionsModel?

  var body: some View {
    if let entry = model.entry(named: entryName), let server = entry.server(on: machineId) {
      content(server: server, status: model.row(for: entry, on: machineId, in: environment)?.status)
    }
  }

  private func content(server: ServerMcpServer, status: McpFleet.MachineStatus?) -> some View {
    VStack(spacing: 0) {
      McpServerDetailHeader(name: server.name, status: status)
      Form {
        McpServerConnectionSection(server: server)
        if let accounts { PluginAccountsSection(model: accounts) }
        if let subscriptions { PluginSubscriptionsSection(model: subscriptions, chatTitle: chatTitle) }
        if !server.isBuiltIn { PluginModerationSection(server: server) }
        if let capabilities = server.capabilityDigest {
          PluginCapabilitySections(capabilities: capabilities)
        } else {
          McpToolsSection(tools: tools, isLoading: isLoadingTools)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        if server.canRemove != false {
          Button("Remove…", role: .destructive) { confirmingRemoval = true }
        }
        if server.authType == "oauth" && isConnected(status) {
          Button("Sign Out") { Task { await disconnect(server) } }
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 540, height: 470)
    .task(id: isConnected(status)) { await loadTools(server) }
    .task(id: server.id) { await loadPluginDetails(server) }
    .confirmationDialog(
      "Remove \(server.name)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove Plugin", role: .destructive) { Task { await remove(server) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes its configuration and saved authorization from Codevisor.")
    }
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }

  private func isConnected(_ status: McpFleet.MachineStatus?) -> Bool {
    if case .ready = status { true } else { false }
  }

  private func loadTools(_ server: ServerMcpServer) async {
    guard server.capabilityDigest == nil else { return }

    isLoadingTools = true
    defer { isLoadingTools = false }
    do {
      tools = try await client.listMcpTools(id: server.id)
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func loadPluginDetails(_ server: ServerMcpServer) async {
    let accounts = PluginAccountsModel(server: server, client: client)
    let subscriptions = PluginSubscriptionsModel(serverId: server.id, client: client)
    self.accounts = accounts
    self.subscriptions = subscriptions
    await accounts.load()
    await subscriptions.load()
  }

  private func chatTitle(_ sessionId: String) -> String? {
    guard let id = UUID(uuidString: sessionId) else { return nil }
    return environment.projectList.session(id, serverId: machineId)?.title
  }

  private func remove(_ server: ServerMcpServer) async {
    do {
      try await client.removeMcpServer(id: server.id)
      dismiss()
      await model.load(in: environment)
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
  }

  private func disconnect(_ server: ServerMcpServer) async {
    do {
      _ = try await client.disconnectMcpOAuth(id: server.id)
      dismiss()
      await model.load(in: environment)
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
  }
}
