import Foundation
import Testing

@testable import CodevisorCore

@Suite("McpFleetSummary")
struct McpFleetSummaryTests {
  @Test("An OAuth plugin waiting on any machine needs sign-in, even if another is connected")
  func pendingAuthorizationWins() throws {
    let summary = try summary(
      authType: "oauth",
      [.ready(toolCount: 4), .needsAuthorization(reason: "Sign in to Linear")])

    #expect(summary.label == "Needs sign-in")
    #expect(summary.needsSignIn)
    #expect(!summary.isSignedIn)
  }

  @Test("A connected OAuth plugin is signed in and reads Connected")
  func connectedOAuth() throws {
    let summary = try summary(authType: "oauth", [.ready(toolCount: 4), .ready(toolCount: 4)])

    #expect(summary.label == "Connected")
    #expect(summary.isSignedIn)
  }

  @Test("Machines turned off or unreachable don't count toward the status")
  func ignoresOffAndUnreachable() throws {
    let partly = try summary(
      authType: "none", [.ready(toolCount: 1), .needsAuthorization(reason: "x")],
      isOn: [true, false])
    let offline = try summary(authType: "oauth", [.ready(toolCount: 1), .unreachable])
    let partlyOffline = try summary(
      authType: "none", [.ready(toolCount: 1), .off, .unreachable], isOn: [true, false, true])

    #expect(partly.label == "On 1 of 2 machines")
    #expect(!partly.needsSignIn)
    #expect(offline.label == "Connected")
    #expect(partlyOffline.label == "On 1 of 2 machines")
  }

  @Test("Attention, then progress, then off, in that order")
  func precedence() throws {
    #expect(try summary(authType: "none", [.connecting, .blocked(reason: "No npx")]).label == "Needs attention")
    #expect(try summary(authType: "none", [.ready(toolCount: 1), .connecting]).label == "Connecting…")
    #expect(try summary(authType: "none", [.off, .off], isOn: [false, false]).label == "Off")
  }

  @Test("A built-in tool that's on everywhere reads On")
  func builtInOn() throws {
    #expect(try summary(kind: "browserUse", authType: "none", [.idle]).label == "On")
  }

  private func summary(
    kind: String = "managed", authType: String, _ statuses: [McpFleet.MachineStatus],
    isOn: [Bool]? = nil
  ) throws -> McpFleetSummary {
    let server = try server(kind: kind, authType: authType)
    let entry = try #require(
      McpFleetEntry(name: server.name, serverByMachine: ["local": server], preferredMachineId: "local"))
    let rows = statuses.enumerated().map { index, status in
      McpFleet.MachineRow(
        machineId: "m\(index)", name: "Machine \(index)", status: status,
        isOn: isOn?[index] ?? true)
    }
    return McpFleetSummary(entry: entry, rows: rows)
  }

  private func server(kind: String, authType: String) throws -> ServerMcpServer {
    let json: [String: Any] = [
      "id": "s1", "name": "Linear", "kind": kind, "transport": "http",
      "url": "https://mcp.example/linear", "args": [], "enabled": true, "authType": authType,
      "connectionState": "connected", "toolCount": 0,
      "createdAt": "2026-10-28T00:00:00.000Z", "updatedAt": "2026-10-28T00:00:00.000Z",
    ]
    return try JSONDecoder().decode(
      ServerMcpServer.self, from: JSONSerialization.data(withJSONObject: json))
  }
}
