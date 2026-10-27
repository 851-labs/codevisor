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
    Section("Tools") {
      if isLoading {
        ProgressView().controlSize(.small)
      } else if tools.isEmpty {
        Text("No tools available").foregroundStyle(.secondary)
      } else {
        ForEach(tools) { tool in
          VStack(alignment: .leading, spacing: 2) {
            Text(tool.title ?? tool.name)
            if let description = tool.description {
              Text(description).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}
