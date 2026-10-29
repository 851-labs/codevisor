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
    PluginToolsDisclosure(count: tools.count, isLoading: isLoading) {
      ForEach(tools) { tool in
        PluginCapabilityRow(name: tool.title ?? tool.name, detail: tool.description)
      }
    }
  }
}
