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
    #expect(HarnessRegistry.fleetHostedSignInIds.sorted() == ["claude-code", "codex", "grok-build", "opencode", "pi"])
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

  @Test("Shared-host candidates: preferred first, then machines reporting ready, then the rest; unreachable never")
  func sharedHostCandidates() {
    let machines: [HarnessFleet.FleetMachine] = [
      .init(id: "a", name: "A", syncKey: "a", isReachable: true),
      .init(id: "b", name: "B", syncKey: "b", isReachable: true),
      .init(id: "c", name: "C", syncKey: "c", isReachable: false),
      .init(id: "d", name: "D", syncKey: nil, isReachable: true),
    ]
    let readiness: [String: [HarnessFleet.MachineReadiness]] = [
      "a": [.init(harnessId: "codex", state: "signInRequired", reason: nil)],
      "b": [.init(harnessId: "codex", state: "ready", reason: nil)],
      "c": [.init(harnessId: "codex", state: "ready", reason: nil)],
    ]
    #expect(
      HarnessFleet.sharedHostCandidates(harnessId: "codex", machines: machines, readiness: readiness, preferred: nil)
        == ["b", "a", "d"])
    #expect(
      HarnessFleet.sharedHostCandidates(harnessId: "codex", machines: machines, readiness: readiness, preferred: "a")
        == ["a", "b", "d"])
    // A preferred machine that is offline is not a candidate at all.
    #expect(
      HarnessFleet.sharedHostCandidates(harnessId: "codex", machines: machines, readiness: readiness, preferred: "c")
        == ["b", "a", "d"])
    #expect(
      HarnessFleet.sharedHostCandidates(harnessId: "codex", machines: [], readiness: readiness, preferred: "a") == [])
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
