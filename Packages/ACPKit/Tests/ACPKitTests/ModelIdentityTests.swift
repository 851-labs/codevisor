import Foundation
import Testing
@testable import ACPKit

@Suite("Model identity")
struct ModelIdentityTests {
    @Test("Identifiable models expose stable ids")
    func ids() {
        #expect(AvailableCommand(name: "test", description: "run").id == "test")
        #expect(PermissionOption(optionId: "ok", name: "Allow", kind: .allowOnce).id == "ok")
        #expect(SessionMode(id: "fast", name: "Fast").id == "fast")
        #expect(AuthMethod(id: "oauth", name: "OAuth").id == "oauth")
    }

    @Test("Plan entries compare by value")
    func planEntries() {
        let a = PlanEntry(content: "do", priority: .medium, status: .inProgress)
        let b = PlanEntry(content: "do", priority: .medium, status: .inProgress)
        #expect(a == b)
        #expect(Plan(entries: [a]) == Plan(entries: [b]))
    }

    @Test("Enum case sets are complete")
    func enumCases() {
        #expect(ToolCallStatus.allCases.count == 4)
        #expect(ToolKind.allCases.contains(.switchMode))
        #expect(PermissionOptionKind.allCases.count == 4)
        #expect(PlanEntryPriority.allCases.count == 3)
        #expect(PlanEntryStatus.allCases.count == 3)
        #expect(StopReason.allCases.count == 5)
    }

    @Test("Empty MCP server lists encode cleanly")
    func mcpEncoding() throws {
        let servers: [McpServer] = [
            .stdio(name: "a", command: "node", args: [], env: []),
            .http(name: "b", url: "https://b", headers: []),
            .sse(name: "c", url: "https://c", headers: [])
        ]
        let data = try ACPJSON.encoder.encode(servers)
        let decoded = try ACPJSON.decoder.decode([McpServer].self, from: data)
        #expect(decoded == servers)
    }
}
