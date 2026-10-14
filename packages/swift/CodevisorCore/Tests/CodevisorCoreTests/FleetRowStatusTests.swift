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
    #expect(PluginFleet.MachineStatus.blocked(reason: "").rowStatus.reason == FleetRowStatus.blockedFallbackReason)
  }

  @Test("Plugin rows follow the report, with offline outranking a stale one")
  func pluginRows() {
    let readiness: [String: [PluginFleet.MachineReadiness]] = [
      "studio-key": [.init(pluginId: "scratch", state: "ready", reason: nil)],
      "book-key": [.init(pluginId: "scratch", state: "blocked", reason: "needs ffmpeg")],
      "vps-key": [.init(pluginId: "scratch", state: "ready", reason: nil)],
    ]
    let rows = PluginFleet.machineRows(
      pluginId: "scratch", readiness: readiness, machines: machines())
    #expect(rows.map(\.machineId) == ["studio", "book", "vps", "fresh"])
    #expect(rows[0].status == .ready)
    #expect(rows[1].status == .blocked(reason: "needs ffmpeg"))
    #expect(rows[1].status.rowStatus.reason == "needs ffmpeg")
    #expect(rows[2].status == .unreachable)
    #expect(rows[3].status == .syncing)
  }

  @Test("A blocked plugin with no reason still says something actionable")
  func pluginBlockedFallback() {
    let rows = PluginFleet.machineRows(
      pluginId: "scratch",
      readiness: ["studio-key": [.init(pluginId: "scratch", state: "blocked", reason: nil)]],
      machines: [machines()[0]])
    #expect(rows[0].status.rowStatus.reason == FleetRowStatus.blockedFallbackReason)
  }

  @Test("MCP rows let the overlay outrank the report, and split auth from other failures")
  func mcpRows() {
    let readiness: [String: [McpFleet.MachineReadiness]] = [
      "studio-key": [.init(name: "Linear", state: "ready", reason: nil, toolCount: 14)],
      "book-key": [
        .init(name: "Linear", state: "blocked", reason: "Sign-in expired", code: "expired")
      ],
      "vps-key": [
        .init(name: "Linear", state: "blocked", reason: "spawn psql ENOENT", code: "error")
      ],
    ]
    let rows = McpFleet.machineRows(
      name: "Linear", readiness: readiness, disabledKeys: ["studio-key"], machines: machines())
    #expect(rows[0].status == .offHere)
    #expect(rows[0].status.isOnHere == false)
    #expect(rows[1].status == .needsAuthorization(reason: "Sign-in expired"))
    #expect(rows[1].status.rowStatus.needsAttention)
    #expect(rows[2].status == .unreachable)
    #expect(rows[3].status == .syncing)
  }

  @Test(
    "A machine still reporting off after the user turned it on reads as syncing on every plane")
  func pendingTurnOnIsBusy() {
    let studio = [machines()[0]]
    let mcp = McpFleet.machineRows(
      name: "Linear",
      readiness: [
        "studio-key": [.init(name: "Linear", state: "disabled", reason: nil)],
        "book-key": [.init(name: "Linear", state: "disabled", reason: nil)],
      ],
      disabledKeys: [], machines: Array(machines()[0...1]),
      wantsOn: { $0 == "studio" })
    #expect(mcp.map(\.status) == [.syncing, .offFleet])
    #expect(mcp[0].status.rowStatus.isBusy)
    let harness = HarnessFleet.machineRows(
      harnessId: "codex",
      readiness: ["studio-key": [.init(harnessId: "codex", state: "disabled", reason: nil)]],
      machines: [.init(id: "studio", name: "Studio", syncKey: "studio-key", isReachable: true)],
      wantsOn: true)
    #expect(harness.map(\.status) == [.syncing])
    let plugin = PluginFleet.machineRows(
      pluginId: "notes",
      readiness: ["studio-key": [.init(pluginId: "notes", state: "disabled", reason: nil)]],
      machines: studio, wantsOn: true)
    #expect(plugin.map(\.status) == [.syncing])
    #expect(
      PluginFleet.machineRows(
        pluginId: "notes",
        readiness: ["studio-key": [.init(pluginId: "notes", state: "disabled", reason: nil)]],
        machines: studio
      ).map(\.status) == [.off])
  }

  @Test("A connected MCP reports the tools it actually exposes there")
  func mcpToolCount() {
    let rows = McpFleet.machineRows(
      name: "Linear",
      readiness: ["studio-key": [.init(name: "Linear", state: "ready", reason: nil, toolCount: 1)]],
      disabledKeys: [],
      machines: [machines()[0]])
    #expect(rows[0].status == .ready(toolCount: 1))
    #expect(rows[0].status.label == "Connected · 1 tool")
  }

  @Test("A machine-bound plugin still counts as running, so it can be restarted")
  func machineBoundPluginIsRunning() {
    #expect(PluginFleet.MachineStatus.localOnly.isRunningHere)
    #expect(PluginFleet.MachineStatus.ready.isRunningHere)
    #expect(PluginFleet.MachineStatus.off.isRunningHere == false)
    #expect(PluginFleet.MachineStatus.blocked(reason: "died").isRunningHere == false)
    #expect(PluginFleet.MachineStatus.ready.rowStatus.isWorthFoldingUp == false)
    #expect(PluginFleet.MachineStatus.off.rowStatus.isWorthFoldingUp == false)
    #expect(PluginFleet.MachineStatus.blocked(reason: "died").rowStatus.isWorthFoldingUp)
    #expect(PluginFleet.MachineStatus.installing.rowStatus.isWorthFoldingUp)
  }

  @Test("Unknown server states degrade to syncing instead of vanishing")
  func unknownStates() {
    #expect(PluginFleet.machineStatus(state: "fromTheFuture", reason: nil) == .syncing)
    let mcp = McpFleet.machineStatus(
      .init(name: "S", state: "fromTheFuture", reason: "odd", code: nil))
    #expect(mcp == .blocked(reason: "odd"))
  }
}
