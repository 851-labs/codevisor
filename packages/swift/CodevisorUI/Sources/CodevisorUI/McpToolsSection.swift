import CodevisorCore
import SwiftUI

public struct McpToolsSection: View {
  let tools: [ServerMcpTool]
  let isLoading: Bool

  public init(tools: [ServerMcpTool], isLoading: Bool) {
    self.tools = tools
    self.isLoading = isLoading
  }

  public var body: some View {
    PluginListDisclosure("Tools", count: tools.count, isLoading: isLoading, emptyText: "No tools available") {
      ForEach(tools) { tool in
        PluginCapabilityRow(name: tool.title ?? tool.name, detail: tool.description)
      }
    }
  }
}
