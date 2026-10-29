import CodevisorCore
import SwiftUI

public struct McpServerToolSections: View {
  private let server: ServerMcpServer
  private let client: any CodevisorServerClienting
  private let isConnected: Bool
  @State private var tools: [ServerMcpTool] = []
  @State private var isLoading = false

  public init(server: ServerMcpServer, client: any CodevisorServerClienting, isConnected: Bool) {
    self.server = server
    self.client = client
    self.isConnected = isConnected
  }

  public var body: some View {
    if let capabilities = server.capabilityDigest {
      PluginCapabilitySections(capabilities: capabilities)
    } else {
      McpToolsSection(tools: tools, isLoading: isLoading)
        .task(id: "\(server.id)|\(isConnected)") { await loadTools() }
    }
  }

  private func loadTools() async {
    isLoading = true
    defer { isLoading = false }
    tools = (try? await client.listMcpTools(id: server.id)) ?? []
  }
}
