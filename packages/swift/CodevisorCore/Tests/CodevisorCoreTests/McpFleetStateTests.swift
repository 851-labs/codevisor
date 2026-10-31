import ACPKit
import ConcurrencyExtras
import Foundation
import Observation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("McpFleetState")
struct McpFleetStateTests {
  private let machines = [
    FleetMachineInfo(id: "local", name: "MacBook Pro", syncKey: "book-key", isReachable: true),
    FleetMachineInfo(id: "studio", name: "Mac Studio", syncKey: "studio-key", isReachable: true),
    FleetMachineInfo(id: "vps", name: "vps-1", syncKey: "vps-key", isReachable: true),
  ]

  @Test("Finishing OAuth updates the row the list and the sheet both read, and re-renders it")
  func oauthCompletionReachesTheList() throws {
    let sync = try makeSync()
    var state = McpFleetState(preferredMachineId: "local")
    for machine in machines {
      state.absorb(
        [try server("Sentry", id: "s-\(machine.id)", connectionState: "needsAuthorization")], from: machine.id)
    }
    for machine in machines {
      report(sync, machine: machine, rows: [needsAuthorization("Sentry")], wallMs: 1)
    }
    let entry = try #require(state.entries.first)
    let before = state.rows(for: entry, sync: sync, machines: machines)
    #expect(before.allSatisfy { $0.status.needsAuthorization })

    let rerendered = LockIsolated(false)
    withObservationTracking {
      _ = state.rows(for: entry, sync: sync, machines: machines)
    } onChange: {
      rerendered.setValue(true)
    }
    report(sync, machine: machines[0], rows: [ready("Sentry", tools: 15)], wallMs: 2)

    #expect(rerendered.value)
    let rows = state.rows(for: entry, sync: sync, machines: machines)
    #expect(rows[0].status == .ready(toolCount: 15))
    #expect(rows[0].status.label == "Connected · 15 tools")
    #expect(rows.map(\.isOn) == [true, true, true])
    #expect(entry.representative.id == "s-local")
  }

  @Test("A toggle holds the user's choice through echoes from every machine, then settles once")
  func toggleNeverBouncesUnderEchoes() throws {
    let sync = try makeSync()
    var state = McpFleetState(preferredMachineId: "local")
    for machine in machines {
      state.absorb([try server("Linear", id: "l-\(machine.id)")], from: machine.id)
      report(sync, machine: machine, rows: [ready("Linear", tools: 4)], wallMs: 1)
    }
    let entry = try #require(state.entries.first)
    var seen: [[Bool]] = []
    let observe = { (state: McpFleetState) in
      seen.append(state.rows(for: entry, sync: sync, machines: machines).map(\.isOn))
    }

    state.intend(false, name: "Linear", on: "studio")
    observe(state)
    let echoes: [(FleetMachineInfo, McpFleet.MachineReadiness)] = [
      (machines[0], ready("Linear", tools: 4)),
      (machines[2], connecting("Linear")),
      (machines[1], ready("Linear", tools: 4)),
      (machines[2], ready("Linear", tools: 4)),
      (machines[1], connecting("Linear")),
    ]
    for (index, (machine, row)) in echoes.enumerated() {
      report(sync, machine: machine, rows: [row], wallMs: 10 + index)
      state.settle(sync: sync, machines: machines)
      observe(state)
    }
    #expect(state.rows(for: entry, sync: sync, machines: machines)[1].status == .syncing)

    report(sync, machine: machines[1], rows: [disabled("Linear")], wallMs: 20)
    state.settle(sync: sync, machines: machines)
    observe(state)
    report(sync, machine: machines[0], rows: [ready("Linear", tools: 4)], wallMs: 21)
    state.settle(sync: sync, machines: machines)
    observe(state)

    #expect(seen.allSatisfy { $0 == [true, false, true] })
    #expect(state.intents.isEmpty)
    #expect(state.rows(for: entry, sync: sync, machines: machines)[1].status == .off)
  }

  @Test("A confirmed choice stops overriding, so a later change from another device shows")
  func settledIntentYieldsToLaterReports() throws {
    let sync = try makeSync()
    var state = McpFleetState(preferredMachineId: "local")
    state.absorb([try server("Linear", id: "l-studio")], from: "studio")
    let entry = try #require(state.entries.first)

    state.intend(true, name: "Linear", on: "studio")
    report(sync, machine: machines[1], rows: [ready("Linear", tools: 4)], wallMs: 1)
    state.settle(sync: sync, machines: machines)
    report(sync, machine: machines[1], rows: [disabled("Linear")], wallMs: 2)

    #expect(state.rows(for: entry, sync: sync, machines: [machines[1]]).map(\.isOn) == [false])
  }

  @Test("An expired intent falls back to the report, but a newer intent outlives an older expiry")
  func expiryOnlyDropsItsOwnIntent() throws {
    let sync = try makeSync()
    var state = McpFleetState(preferredMachineId: "local")
    state.absorb([try server("Linear", id: "l-studio")], from: "studio")
    report(sync, machine: machines[1], rows: [ready("Linear", tools: 4)], wallMs: 1)
    let entry = try #require(state.entries.first)
    let rows = { state.rows(for: entry, sync: sync, machines: [machines[1]]) }

    let first = state.intend(false, name: "Linear", on: "studio")
    let second = state.intend(true, name: "Linear", on: "studio")
    state.intend(false, name: "Linear", on: "studio")
    state.abandon(name: "Linear", on: "studio", token: first)
    state.abandon(name: "Linear", on: "studio", token: second)
    #expect(rows().map(\.isOn) == [false])

    state.abandon(name: "Linear", on: "studio", token: second + 1)
    #expect(rows().map(\.isOn) == [true])
    #expect(rows().map { $0.status == .syncing } == [false])
  }

  @Test("A reload that misses a machine keeps that machine's last servers")
  func partialReloadKeepsOtherMachines() throws {
    var state = McpFleetState(preferredMachineId: "local")
    state.absorb([try server("Linear", id: "l-local")], from: "local")
    state.absorb([try server("Linear", id: "l-studio")], from: "studio")

    state.absorb([try server("Linear", id: "l-local"), try server("Sentry", id: "s-local")], from: "local")
    #expect(state.entries.map(\.name) == ["Linear", "Sentry"])
    #expect(state.entries.first?.idByMachine == ["local": "l-local", "studio": "l-studio"])

    state.retainMachines(["local"])
    #expect(state.entries.first?.idByMachine == ["local": "l-local"])
  }

  private func makeSync() throws -> ConfigSync {
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local")), forKey: "machines")
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) })
    return ConfigSync(machines: controller, store: store)
  }

  private func report(
    _ sync: ConfigSync, machine: FleetMachineInfo, rows: [McpFleet.MachineReadiness], wallMs: Int
  ) {
    let servers: [JSONValue] = rows.map { row in
      var fields: [String: JSONValue] = ["name": .string(row.name), "state": .string(row.state)]
      if let reason = row.reason { fields["reason"] = .string(reason) }
      if let code = row.code { fields["code"] = .string(code) }
      if let toolCount = row.toolCount { fields["toolCount"] = .number(Double(toolCount)) }
      return .object(fields)
    }
    sync.applyRemoteChange(
      namespace: "mcp-readiness",
      entries: [
        ServerSyncEntry(
          key: machine.syncKey ?? machine.id,
          value: .object(["servers": .array(servers)]),
          timestamp: ServerSyncTimestamp(wallMs: wallMs, counter: 0, deviceId: machine.id))
      ])
  }

  private func ready(_ name: String, tools: Int) -> McpFleet.MachineReadiness {
    .init(name: name, state: "ready", reason: nil, toolCount: tools)
  }

  private func connecting(_ name: String) -> McpFleet.MachineReadiness {
    .init(name: name, state: "connecting", reason: nil)
  }

  private func disabled(_ name: String) -> McpFleet.MachineReadiness {
    .init(name: name, state: "disabled", reason: "Disabled on this machine")
  }

  private func needsAuthorization(_ name: String) -> McpFleet.MachineReadiness {
    .init(name: name, state: "blocked", reason: "Needs authorization", code: "needsAuthorization")
  }

  private func server(
    _ name: String, id: String, connectionState: String = "connected"
  ) throws -> ServerMcpServer {
    let json: [String: Any] = [
      "id": id, "name": name, "kind": "managed", "transport": "http",
      "url": "https://mcp.example/\(name)", "args": [], "enabled": true, "authType": "oauth",
      "connectionState": connectionState, "toolCount": 0,
      "createdAt": "2026-10-22T00:00:00.000Z", "updatedAt": "2026-10-22T00:00:00.000Z",
    ]
    return try JSONDecoder().decode(
      ServerMcpServer.self, from: JSONSerialization.data(withJSONObject: json))
  }
}
