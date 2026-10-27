import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("FleetRowStatus")
struct FleetRowStatusTests {
  private func machines() -> [FleetMachineInfo] {
    [
      FleetMachineInfo(id: "studio", name: "Studio", syncKey: "studio-key", isReachable: true),
      FleetMachineInfo(id: "book", name: "MacBook", syncKey: "book-key", isReachable: true),
      FleetMachineInfo(id: "vps", name: "vps-1", syncKey: "vps-key", isReachable: false),
      FleetMachineInfo(id: "fresh", name: "Fresh", syncKey: nil, isReachable: true),
    ]
  }

  @Test("A status is exactly one of ready, busy, attention, or quiet")
  func emphasisIsExclusive() {
    let statuses: [FleetRowStatus] = [
      .ready(), .busy("Installing…"), .attention("Needs attention", reason: "boom"), .quiet("Off"),
      .unreachable, .syncing,
    ]
    for status in statuses {
      let flags = [status.emphasis == .ready, status.isBusy, status.needsAttention, status.emphasis == .quiet]
      #expect(flags.filter { $0 }.count == 1, "\(status.label) claimed more than one emphasis")
    }
  }

  @Test("An attention status never opens an empty explanation")
  func attentionAlwaysExplains() {
    #expect(FleetRowStatus.attention("Needs attention", reason: "  ").reason == FleetRowStatus.blockedFallbackReason)
  }

  @Test("MCP rows follow each machine's own report, and split auth from other failures")
  func mcpRows() {
    let readiness: [String: [McpFleet.MachineReadiness]] = [
      "studio-key": [.init(name: "Linear", state: "disabled", reason: "Disabled on this machine")],
      "book-key": [
        .init(name: "Linear", state: "blocked", reason: "Sign-in expired", code: "expired")
      ],
      "vps-key": [
        .init(name: "Linear", state: "blocked", reason: "spawn psql ENOENT", code: "error")
      ],
    ]
    let rows = McpFleet.machineRows(name: "Linear", readiness: readiness, machines: machines())
    #expect(
      rows.map(\.status) == [
        .off, .needsAuthorization(reason: "Sign-in expired"), .unreachable, .syncing,
      ])
    #expect(rows.map(\.isOn) == [false, true, true, true])
    #expect(rows[1].status.rowStatus.needsAttention)
  }

  @Test(
    "A machine still reporting off after the user turned it on reads as syncing on every plane")
  func pendingTurnOnIsBusy() {
    let mcp = McpFleet.machineRows(
      name: "Linear",
      readiness: [
        "studio-key": [.init(name: "Linear", state: "disabled", reason: nil)],
        "book-key": [.init(name: "Linear", state: "disabled", reason: nil)],
      ],
      machines: Array(machines()[0...1]),
      intents: ["studio": true])
    #expect(mcp.map(\.status) == [.syncing, .off])
    #expect(mcp.map(\.isOn) == [true, false])
    #expect(mcp[0].status.rowStatus.isBusy)
    let harness = HarnessFleet.machineRows(
      harnessId: "codex",
      readiness: ["studio-key": [.init(harnessId: "codex", state: "disabled", reason: nil)]],
      machines: [.init(id: "studio", name: "Studio", syncKey: "studio-key", isReachable: true)],
      wantsOn: true)
    #expect(harness.map(\.status) == [.syncing])
  }

  @Test("A connected MCP reports the tools it actually exposes there")
  func mcpToolCount() {
    let rows = McpFleet.machineRows(
      name: "Linear",
      readiness: ["studio-key": [.init(name: "Linear", state: "ready", reason: nil, toolCount: 1)]],
      machines: [machines()[0]])
    #expect(rows[0].status == .ready(toolCount: 1))
    #expect(rows[0].status.label == "Connected · 1 tool")
  }

  @Test("An unknown MCP state still shows the reason the machine gave")
  func unknownStates() {
    let mcp = McpFleet.machineStatus(
      .init(name: "S", state: "fromTheFuture", reason: "odd", code: nil))
    #expect(mcp == .blocked(reason: "odd"))
  }
}
