import Foundation
import ACPKit

/// Semantic presentation for Codevisor's tool gateway. Each harness spells MCP
/// names differently (`codevisor.execute`, `mcp__codevisor__execute`, or
/// `codevisor_execute`), but the transcript should describe the user's action,
/// not the adapter's wire format.
public enum CodevisorGatewayOperation: String {
  case execute
}

extension ToolCall {
  public var codevisorGatewayOperation: CodevisorGatewayOperation? {
    let normalized =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let prefixes = [
      "mcp__codevisor__", "codevisor.", "codevisor_",
      // Persisted transcripts keep their original wire-level tool names.
      "mcp__herdman__", "herdman.", "herdman_",
    ]
    let operation = prefixes.first(where: normalized.hasPrefix).map {
      String(normalized.dropFirst($0.count))
    }
    return operation.flatMap(CodevisorGatewayOperation.init(rawValue:))
  }

  /// Codex's built-in tool discovery is part of the same integration flow
  /// when it appears beside Codevisor calls, and deserves a readable label.
  public var isToolDiscoveryCall: Bool {
    let normalized =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
    return normalized == "toolsearch"
  }

  public var isIntegrationPresentationCall: Bool {
    codevisorGatewayOperation != nil || isToolDiscoveryCall
  }

  public func integrationDisplayTitle() -> String? {
    if isToolDiscoveryCall {
      return isSettled ? "Searched available tools" : "Searching available tools…"
    }
    guard let operation = codevisorGatewayOperation else { return nil }
    switch operation {
    case .execute:
      return isSettled ? "Ran an integration workflow" : "Running an integration workflow…"
    }
  }
}
