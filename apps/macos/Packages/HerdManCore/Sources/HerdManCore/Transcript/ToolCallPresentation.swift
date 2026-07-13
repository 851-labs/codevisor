import Foundation
import ACPKit

/// Semantic presentation for HerdMan's tool gateway. Each harness spells MCP
/// names differently (`herdman.search`, `mcp__herdman__search`, or
/// `herdman_search`), but the transcript should describe the user's action,
/// not the adapter's wire format.
enum HerdManGatewayOperation: String {
    case search
    case describe
    case execute
    case runCode = "run_code"
}

extension ToolCall {
    var herdManGatewayOperation: HerdManGatewayOperation? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let operation: String?
        if normalized.hasPrefix("mcp__herdman__") {
            operation = String(normalized.dropFirst("mcp__herdman__".count))
        } else if normalized.hasPrefix("herdman.") {
            operation = String(normalized.dropFirst("herdman.".count))
        } else if normalized.hasPrefix("herdman_") {
            operation = String(normalized.dropFirst("herdman_".count))
        } else {
            operation = nil
        }
        return operation.flatMap(HerdManGatewayOperation.init(rawValue:))
    }

    /// Codex's built-in tool discovery is part of the same integration flow
    /// when it appears beside HerdMan calls, and deserves a readable label.
    var isToolDiscoveryCall: Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
        return normalized == "toolsearch"
    }

    var isIntegrationPresentationCall: Bool {
        herdManGatewayOperation != nil || isToolDiscoveryCall
    }

    func integrationDisplayTitle() -> String? {
        if isToolDiscoveryCall {
            return isSettled ? "Searched available tools" : "Searching available tools…"
        }
        guard let operation = herdManGatewayOperation else { return nil }
        switch operation {
        case .search:
            let query = rawInput?["query"]?.stringValue?.trimmedNonempty
            if let query {
                return isSettled
                    ? "Searched integrations for \(query)"
                    : "Searching integrations for \(query)…"
            }
            return isSettled ? "Searched integrations" : "Searching integrations…"
        case .describe:
            let tool = rawInput?["tool"]?.stringValue?.humanizedToolName
            if let tool {
                return isSettled ? "Inspected \(tool)" : "Inspecting \(tool)…"
            }
            return isSettled ? "Inspected an integration tool" : "Inspecting an integration tool…"
        case .execute:
            let tool = rawInput?["tool"]?.stringValue?.humanizedToolName
            if let tool {
                return isSettled ? "Ran \(tool)" : "Running \(tool)…"
            }
            return isSettled ? "Ran an integration tool" : "Running an integration tool…"
        case .runCode:
            return isSettled ? "Ran an integration workflow" : "Running an integration workflow…"
        }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var humanizedToolName: String? {
        trimmedNonempty?
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}
