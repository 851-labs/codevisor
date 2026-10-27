import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpServerDetailScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  let server: ServerMcpServer
  let client: any CodevisorServerClienting
  @State private var tools: [ServerMcpTool] = []
  @State private var isLoadingTools = false
  @State private var accounts: PluginAccountsModel?
  @State private var subscriptions: PluginSubscriptionsModel?

  var body: some View {
    NavigationStack {
      List {
        if let accounts { PluginAccountsSection(model: accounts) }
        if let subscriptions { PluginSubscriptionsSection(model: subscriptions, chatTitle: chatTitle) }
        if !server.isBuiltIn { PluginModerationSection(server: server) }
        if let capabilities = server.capabilityDigest {
          PluginCapabilitySections(capabilities: capabilities)
        } else {
          McpToolsSection(tools: tools, isLoading: isLoadingTools)
        }
      }
      .navigationTitle(server.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await loadTools() }
      .task(id: server.id) { await loadPluginDetails() }
    }
  }

  private func loadPluginDetails() async {
    let accounts = PluginAccountsModel(server: server, client: client)
    let subscriptions = PluginSubscriptionsModel(serverId: server.id, client: client)
    self.accounts = accounts
    self.subscriptions = subscriptions
    await accounts.load()
    await subscriptions.load()
  }

  private func chatTitle(_ sessionId: String) -> String? {
    guard let id = UUID(uuidString: sessionId) else { return nil }
    return environment?.projectList.sessions.first { $0.id == id }?.title
  }

  private func loadTools() async {
    guard server.capabilityDigest == nil else { return }

    isLoadingTools = true
    defer { isLoadingTools = false }
    tools = (try? await client.listMcpTools(id: server.id)) ?? []
  }
}
