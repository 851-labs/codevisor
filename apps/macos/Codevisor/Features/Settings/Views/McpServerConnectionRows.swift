import CodevisorCore
import SwiftUI

struct McpServerConnectionRows: View {
  let server: ServerMcpServer

  var body: some View {
    LabeledContent("Transport", value: server.transport == "http" ? "HTTP" : "Local command")
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
  }

  private var authorizationLabel: String {
    switch server.authType {
    case "oauth": return "OAuth"
    case "bearer": return "Bearer token"
    default: return "None"
    }
  }
}
