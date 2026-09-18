import ACPKit
import Foundation
import Observation
import Synchronization
import Testing

@testable import CodevisorCore

/// Phase 24's client half: parsing each machine's reported harness states.
@MainActor
@Suite("HarnessFleetStatus")
struct HarnessFleetStatusTests {
  @Test("Global edits and readiness changes invalidate observed settings")
  func liveSettings() throws {
    let sync = try makeSync()
    let desiredChanged = Mutex(false)
    withObservationTracking {
      _ = HarnessFleet.settings(sync)
    } onChange: {
      desiredChanged.withLock { $0 = true }
    }
    HarnessFleet.set(
      .init(id: "codex", name: "Codex", symbolName: "terminal", enabled: true, installed: true), in: sync)
    #expect(desiredChanged.withLock { $0 })
    let reportChanged = Mutex(false)
    withObservationTracking {
      _ = HarnessFleet.readiness(sync)
    } onChange: {
      reportChanged.withLock { $0 = true }
    }
    sync.set(namespace: "harness-readiness", key: "local", value: .object(["harnesses": .array([])]))
    #expect(reportChanged.withLock { $0 })
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

  @Test("Readiness entries parse per machine, skipping malformed rows")
  func readinessParses() throws {
    let sync = try makeSync()
    sync.applyRemoteChange(
      namespace: "harness-readiness",
      entries: [
        ServerSyncEntry(
          key: "studio",
          value: .object([
            "harnesses": .array([
              .object(["id": .string("claude-code"), "state": .string("ready")]),
              .object([
                "id": .string("codex"),
                "state": .string("signInRequired"),
              ]),
              .object([
                "id": .string("gemini"),
                "state": .string("notInstalled"),
                "reason": .string("CLI not found on PATH"),
              ]),
              .object(["state": .string("orphan")]),  // malformed: no id
            ])
          ]),
          timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
        ),
        ServerSyncEntry(
          key: "junk",
          value: .string("not an object"),
          timestamp: ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "junk")
        ),
      ]
    )
    let readiness = HarnessFleet.readiness(sync)
    #expect(readiness.keys.sorted() == ["studio"])
    let rows = readiness["studio"] ?? []
    #expect(rows.map(\.harnessId) == ["claude-code", "codex", "gemini"])
    #expect(rows[1].state == "signInRequired")
    #expect(rows[2].reason == "CLI not found on PATH")
  }

  @Test("Global settings distinguish managed installations from legacy absence")
  func globalSettings() throws {
    let sync = try makeSync()
    let stamp = ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "studio")
    sync.apply(
      namespace: "harnesses",
      incoming: [
        ServerSyncEntry(
          key: "legacy-missing", value: .object(["enabled": .bool(false), "installed": .bool(false)]), timestamp: stamp),
        ServerSyncEntry(
          key: "codex", value: .object(["name": .string("Codex"), "enabled": .bool(true), "installed": .bool(true)]),
          timestamp: stamp),
        ServerSyncEntry(
          key: "claude",
          value: .object([
            "name": .string("Claude"), "enabled": .bool(false), "installed": .bool(false), "uninstall": .bool(true),
          ]), timestamp: stamp),
      ])
    let settings = HarnessFleet.settings(sync)
    #expect(settings.map(\.id) == ["codex"])
    #expect(settings[0].enabled)
    #expect(HarnessFleet.settings(sync, includingUninstalled: true).map(\.id) == ["claude", "codex"])
  }

  @Test("Uninstall hides a harness while retaining its instruction for offline machines; Add restores it")
  func uninstallAndReadd() throws {
    let sync = try makeSync()
    var setting = HarnessFleet.Setting(
      id: "codex", name: "Codex", symbolName: "terminal", enabled: true, installed: true)
    HarnessFleet.set(setting, in: sync)
    setting.installed = false
    setting.enabled = false
    HarnessFleet.set(setting, in: sync)
    #expect(HarnessFleet.settings(sync).isEmpty)
    let entry = try #require(sync.entries(namespace: "harnesses").first { $0.key == "codex" })
    #expect(entry.deleted != true)
    guard case .object(let fields) = entry.value else { Issue.record("Expected uninstall instruction"); return }
    #expect(fields["uninstall"] == .bool(true))
    setting.installed = true
    setting.enabled = true
    HarnessFleet.set(setting, in: sync)
    #expect(HarnessFleet.settings(sync) == [setting])
  }
}
