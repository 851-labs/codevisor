import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct HarnessRegistryTests {
  @Test("Every built-in harness has a name and resolves to itself")
  func builtinNames() {
    for descriptor in HarnessRegistry.builtin {
      // Some brands style their name like their id (`goose`); that's the
      // vendor's spelling, not a missing name.
      #expect(!descriptor.displayName.isEmpty)
      #expect(HarnessRegistry.descriptor(for: descriptor.id) == descriptor)
    }
    #expect(HarnessRegistry.displayName(for: "claude-code") == "Claude Code")
    #expect(HarnessRegistry.displayName(for: "codex") == "Codex")
  }

  @Test("Unknown ids are machine-scoped and humanized rather than shown raw")
  func unknownIds() {
    let custom = HarnessRegistry.descriptor(for: "my-custom_bot")
    #expect(custom.displayName == "My Custom Bot")
    #expect(custom.accountScope == .machine)
    #expect(!custom.sharesFleetAccounts)
    #expect(!custom.fleetSignInNeedsMachine)
  }

  @Test("A machine's reported name wins over the registry; an empty one does not")
  func reportedNames() {
    #expect(HarnessRegistry.displayName(for: "claude-code", reported: "Claude Code (beta)") == "Claude Code (beta)")
    #expect(HarnessRegistry.displayName(for: "claude-code", reported: "") == "Claude Code")
    #expect(HarnessRegistry.displayName(for: "claude-code", reported: nil) == "Claude Code")
  }

  @Test("Account scope answers every question the screens used to keep lists for")
  func accountScopes() {
    // Server-side shared account rows: one RPC, sign-in hosted on a machine.
    for id in ["claude-code", "codex", "grok-build"] {
      let descriptor = HarnessRegistry.descriptor(for: id)
      #expect(descriptor.usesFleetAccountRows)
      #expect(descriptor.sharesFleetAccounts)
      #expect(descriptor.fleetSignInNeedsMachine)
    }
    // Replica credentials with OAuth: fleet-shared, assembled client-side,
    // browser flows need a machine.
    for id in ["opencode", "pi"] {
      let descriptor = HarnessRegistry.descriptor(for: id)
      #expect(!descriptor.usesFleetAccountRows)
      #expect(descriptor.sharesFleetAccounts)
      #expect(descriptor.fleetSignInNeedsMachine)
    }
    // Replica credentials only: nothing to host.
    let devin = HarnessRegistry.descriptor(for: "devin")
    #expect(devin.sharesFleetAccounts)
    #expect(!devin.fleetSignInNeedsMachine)
    // Machine-bound.
    #expect(!HarnessRegistry.descriptor(for: "cursor").sharesFleetAccounts)
    #expect(HarnessRowState.sharesFleetAccounts(harnessId: "opencode"))
    #expect(!HarnessRowState.sharesFleetAccounts(harnessId: "cursor"))
  }

  @Test("Multiple accounts are a per-harness fact")
  func multipleAccounts() {
    #expect(HarnessRegistry.descriptor(for: "claude-code").supportsMultipleAccounts)
    #expect(HarnessRegistry.descriptor(for: "codex").supportsMultipleAccounts)
    #expect(HarnessRegistry.descriptor(for: "opencode").supportsMultipleAccounts)
    #expect(!HarnessRegistry.descriptor(for: "grok-build").supportsMultipleAccounts)
    #expect(!HarnessRegistry.descriptor(for: "pi").supportsMultipleAccounts)
  }

  @Test("Catalog rows without a name render the registry's name, not the id")
  func catalogRowNameFallback() throws {
    let sync = try makeSync()
    let stamp = ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
    sync.apply(
      namespace: "harnesses",
      incoming: [
        ServerSyncEntry(
          key: "claude-code", value: .object(["enabled": .bool(true), "installed": .bool(true)]), timestamp: stamp),
        ServerSyncEntry(
          key: "codex", value: .object(["name": .string("Codex"), "enabled": .bool(true), "installed": .bool(true)]),
          timestamp: stamp),
        ServerSyncEntry(
          key: "some-acp-bot", value: .object(["name": .string(""), "enabled": .bool(true), "installed": .bool(true)]),
          timestamp: stamp),
      ])
    let settings = HarnessFleet.settings(sync)
    #expect(settings.map(\.name) == ["Claude Code", "Codex", "Some Acp Bot"])
    #expect(settings.first { $0.id == "claude-code" }?.symbolName == "sparkle")
  }

  @Test(
    "Shared-host candidates: preferred, then this machine, then installed, then unreported; never offline or missing it"
  )
  func sharedHostCandidates() {
    let machines: [HarnessFleet.FleetMachine] = [
      .init(id: "a", name: "A", syncKey: "a", isReachable: true),
      .init(id: "b", name: "B", syncKey: "b", isReachable: true),
      .init(id: "c", name: "C", syncKey: "c", isReachable: false),
      .init(id: "d", name: "D", syncKey: nil, isReachable: true),
      .init(id: "e", name: "E", syncKey: "e", isReachable: true),
      .init(id: "local", name: "Local", syncKey: "local", isReachable: true, isLocal: true),
    ]
    let readiness: [String: [HarnessFleet.MachineReadiness]] = [
      // Signed out is still a host: hosting only needs the harness installed.
      "a": [.init(harnessId: "codex", state: "signInRequired", reason: nil, installed: true)],
      "b": [.init(harnessId: "codex", state: "ready", reason: nil)],
      "c": [.init(harnessId: "codex", state: "ready", reason: nil)],
      "e": [.init(harnessId: "codex", state: "notInstalled", reason: nil)],
      "local": [.init(harnessId: "codex", state: "signInRequired", reason: nil)],
    ]
    let candidates = { (preferred: String?, machines: [HarnessFleet.FleetMachine]) in
      HarnessFleet.sharedHostCandidates(
        harnessId: "codex", machines: machines, readiness: readiness, preferred: preferred)
    }
    #expect(candidates(nil, machines) == ["local", "a", "b", "d"])
    #expect(candidates("b", machines) == ["b", "local", "a", "d"])
    // An offline preferred machine, or one without the harness, is not a candidate at all.
    #expect(candidates("c", machines) == ["local", "a", "b", "d"])
    #expect(candidates("e", machines) == ["local", "a", "b", "d"])
    // A local machine reporting no harness is skipped like any other.
    let missingLocally = readiness.merging(
      ["local": [.init(harnessId: "codex", state: "notInstalled", reason: nil)]]) { $1 }
    #expect(
      HarnessFleet.sharedHostCandidates(
        harnessId: "codex", machines: machines, readiness: missingLocally, preferred: nil) == ["a", "b", "d"])
    #expect(candidates("a", []) == [])
  }

  private func makeSync() throws -> ConfigSync {
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local")),
      forKey: "machines"
    )
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    return ConfigSync(machines: controller, store: store)
  }
}
