import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// The harness-major read: one shared harness, every machine's word on it.
@MainActor
@Suite("HarnessFleetMachineStatus")
struct HarnessFleetMachineStatusTests {
  typealias Status = HarnessFleet.MachineStatus

  private func machine(_ id: String, syncKey: String? = nil, reachable: Bool = true) -> HarnessFleet.FleetMachine {
    .init(id: id, name: id.capitalized, syncKey: syncKey ?? id, isReachable: reachable)
  }

  private func row(_ machineId: String, _ status: Status) -> HarnessFleet.MachineRow {
    .init(machineId: machineId, name: machineId.capitalized, status: status)
  }

  @Test(
    "Every reported state maps to one row status; unknown states read as still syncing",
    arguments: [
      ("ready", Status.ready), ("installing", .installing), ("uninstalling", .removing),
      ("signInRequired", .signInRequired), ("notInstalled", .waiting), ("disabled", .off),
      ("blocked", .blocked(reason: "Package manager unavailable")), ("someday", .syncing),
    ])
  func mapsServerStates(state: String, expected: Status) {
    #expect(HarnessFleet.machineStatus(state: state, reason: "Package manager unavailable") == expected)
  }

  @Test("A blocked report without a reason still has something to show")
  func blockedFallback() {
    #expect(
      HarnessFleet.machineStatus(state: "blocked", reason: nil)
        == .blocked(reason: HarnessFleet.blockedFallbackReason))
  }

  @Test("A machine either needs the user, is still catching up, or is quiet — never two at once")
  func flags() {
    let attention: [Status] = [.signInRequired, .blocked(reason: "x")]
    let busy: [Status] = [.installing, .removing, .waiting, .syncing, .syncingSignIn]
    let quiet: [Status] = [.ready, .off, .unreachable, .awaitingSignIn]
    for status in attention {
      #expect(status.needsAttention && !status.isBusy, "\(status)")
    }
    for status in busy {
      #expect(status.isBusy && !status.needsAttention, "\(status)")
    }
    for status in quiet {
      #expect(!status.isBusy && !status.needsAttention, "\(status)")
    }
  }

  @Test("An unreachable machine's stale report is not shown; unprobed or unreported machines are syncing")
  func reachabilityAndMissingReports() {
    let readiness: [String: [HarnessFleet.MachineReadiness]] = [
      "offline": [.init(harnessId: "codex", state: "signInRequired", reason: nil)],
      "studio": [.init(harnessId: "claude-code", state: "ready", reason: nil)],
    ]
    let rows = HarnessFleet.machineRows(
      harnessId: "codex", readiness: readiness,
      machines: [
        machine("offline", reachable: false),
        machine("unprobed", syncKey: nil),
        machine("silent"),
        machine("studio"),
      ])
    #expect(rows.map(\.status) == [.unreachable, .syncing, .syncing, .syncing])
  }

  @Test(
    "A machine's 'sign in required' reads differently depending on where the account lives",
    arguments: [
      (HarnessFleet.SharedSignIn.notShared, Status.signInRequired),
      (.pending, .awaitingSignIn),
      (.signedIn, .syncingSignIn),
      (.unresolved, .signInRequired),
    ])
  func sharedSignIn(sharing: HarnessFleet.SharedSignIn, expected: Status) {
    let readiness: [String: [HarnessFleet.MachineReadiness]] = [
      "a": [.init(harnessId: "claude-code", state: "signInRequired", reason: nil)],
      "b": [.init(harnessId: "claude-code", state: "blocked", reason: "boom")],
    ]
    let rows = HarnessFleet.machineRows(
      harnessId: "claude-code", readiness: readiness, machines: [machine("a"), machine("b")], sharedSignIn: sharing)
    #expect(rows.map(\.status) == [expected, .blocked(reason: "boom")])
  }

  @Test("Rows keep machine order regardless of state")
  func machineOrder() {
    let readiness: [String: [HarnessFleet.MachineReadiness]] = [
      "a": [.init(harnessId: "codex", state: "ready", reason: nil)],
      "b": [.init(harnessId: "codex", state: "blocked", reason: "boom")],
      "c": [.init(harnessId: "codex", state: "installing", reason: nil)],
    ]
    let rows = HarnessFleet.machineRows(
      harnessId: "codex", readiness: readiness, machines: [machine("c"), machine("b"), machine("a")])
    #expect(rows.map(\.machineId) == ["c", "b", "a"])
    #expect(rows.map(\.status) == [.installing, .blocked(reason: "boom"), .ready])
    #expect(rows.map(\.name) == ["C", "B", "A"])
  }

  @Test("Status reads each machine's replica row for the harness")
  func statusFromReplica() throws {
    let sync = try makeSync()
    sync.set(
      namespace: "harness-readiness", key: "studio",
      value: .object([
        "harnesses": .array([
          .object(["id": .string("claude-code"), "state": .string("ready")]),
          .object(["id": .string("codex"), "state": .string("blocked"), "reason": .string("No install method")]),
        ])
      ]))
    sync.set(
      namespace: "harness-readiness", key: "laptop",
      value: .object(["harnesses": .array([.object(["id": .string("codex"), "state": .string("signInRequired")])])]))
    let machines = [machine("studio"), machine("laptop"), machine("unprobed", syncKey: nil)]

    let codex = HarnessFleet.status(harnessId: "codex", sync: sync, machines: machines)
    #expect(codex.machines.map(\.status) == [.blocked(reason: "No install method"), .signInRequired, .syncing])
    #expect(codex.machines.contains { $0.status.needsAttention })

    let claude = HarnessFleet.status(harnessId: "claude-code", sync: sync, machines: machines)
    #expect(claude.machines.map(\.status) == [.ready, .syncing, .syncing])
    #expect(!claude.machines.contains { $0.status.needsAttention })
  }

  private func makeSync() throws -> ConfigSync {
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local", remoteMachines: [])),
      forKey: "machines"
    )
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    return ConfigSync(machines: controller, store: store)
  }
}
