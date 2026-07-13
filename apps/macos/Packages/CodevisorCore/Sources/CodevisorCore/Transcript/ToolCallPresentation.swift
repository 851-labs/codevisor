import Foundation
import ACPKit

/// Semantic presentation for Codevisor's tool gateway. Each harness spells MCP
/// names differently (`codevisor.search`, `mcp__codevisor__search`, or
/// `codevisor_search`), but the transcript should describe the user's action,
/// not the adapter's wire format.
enum CodevisorGatewayOperation: String {
    case search
    case describe
    case execute
    case runCode = "run_code"
}

extension ToolCall {
    var codevisorGatewayOperation: CodevisorGatewayOperation? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let prefixes = [
            "mcp__codevisor__", "codevisor.", "codevisor_",
            // Persisted transcripts keep their original wire-level tool names.
            "mcp__herdman__", "herdman.", "herdman_"
        ]
        let operation = prefixes.first(where: normalized.hasPrefix).map {
            String(normalized.dropFirst($0.count))
        }
        return operation.flatMap(CodevisorGatewayOperation.init(rawValue:))
    }

    /// Codex's built-in tool discovery is part of the same integration flow
    /// when it appears beside Codevisor calls, and deserves a readable label.
    var isToolDiscoveryCall: Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
        return normalized == "toolsearch"
    }

    var isIntegrationPresentationCall: Bool {
        codevisorGatewayOperation != nil || isToolDiscoveryCall
    }

    func integrationDisplayTitle() -> String? {
        if isToolDiscoveryCall {
            return isSettled ? "Searched available tools" : "Searching available tools…"
        }
        guard let operation = codevisorGatewayOperation else { return nil }
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
