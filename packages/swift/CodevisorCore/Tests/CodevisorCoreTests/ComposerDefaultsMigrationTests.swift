import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDefaultsMigration")
struct ComposerDefaultsMigrationTests {
  @Test("Migrates V6: the last New Chat machine wins and old values apply to each remembered model only")
  func migratesV6() throws {
    let projectId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let version6 =
      #"{"lastNewWorkspaceServerId":"remote-a","machines":{"local":{"lastHarnessId":"claude-code","configSelections":{"claude-code":{"model":"opus","effort":"low","speed":"fast"},"codex":{"model":"gpt-5.6","effort":"high"}}},"remote-a":{"lastHarnessId":"codex","lastProjectId":"00000000-0000-0000-0000-000000000002","worktreeByProject":{"00000000-0000-0000-0000-000000000002":true},"configSelections":{"claude-code":{"model":"sonnet","effort":"high"}}}},"version":6}"#
    let data = Data(version6.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": data])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.configSelections(forHarness: "claude-code", model: nil) == ["model": "sonnet"])
    #expect(
      defaults.configSelections(forHarness: "claude-code", model: "sonnet") == ["model": "sonnet", "effort": "high"])
    #expect(
      defaults.configSelections(forHarness: "claude-code", model: "opus") == [
        "model": "opus", "effort": "low", "speed": "fast",
      ])
    #expect(defaults.configSelections(forHarness: "codex", model: "gpt-5.6") == ["model": "gpt-5.6", "effort": "high"])
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(defaults.lastProjectId(forServer: "remote-a") == projectId)
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectId))
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == data)
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 7)
    let machines = try #require(object["machines"] as? [String: [String: Any]])
    #expect(machines.values.allSatisfy { $0["configSelections"] == nil })
  }

  @Test("Migrates V5: machine defaults survive, workspace profiles are dropped")
  func migratesV5() throws {
    let projectId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let version5 =
      #"{"lastNewWorkspaceServerId":"remote-a","machines":{"remote-a":{"lastHarnessId":"codex","lastProjectId":"00000000-0000-0000-0000-000000000002","newWorkspaceInWorktree":true,"configSelections":{"codex":{"model":"gpt-5.6","effort":"high"}}}},"version":5,"workspaces":{"00000000-0000-0000-0000-000000000003":{"serverId":"remote-a","lastHarnessId":"claude-code","configSelections":{"claude-code":{"model":"opus"}}}}}"#
    let data = Data(version5.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": data])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastNewWorkspaceServerId == "remote-a")
    #expect(defaults.lastProjectId(forServer: "remote-a") == projectId)
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(defaults.configSelections(forHarness: "codex", model: "gpt-5.6") == ["model": "gpt-5.6", "effort": "high"])
    #expect(defaults.configSelections(forHarness: "claude-code", model: nil).isEmpty)
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectId))
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == data)
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 7)
    #expect(object["workspaces"] == nil)
  }

  @Test("Migrates V4 keeping machine defaults and dropping workspace profiles")
  func migratesV4() throws {
    let projectId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let version4 =
      #"{"machines":{"remote-a":{"lastHarnessId":"codex","lastProjectId":"00000000-0000-0000-0000-000000000002","newWorkspaceInWorktree":true,"configSelections":{"codex":{"model":"gpt-5.6"}}}},"version":4,"workspaces":{"00000000-0000-0000-0000-000000000003":{"serverId":"remote-a","lastHarnessId":"claude-code","configSelections":{"claude-code":{"model":"opus"}}}}}"#
    let data = Data(version4.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": data])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastNewWorkspaceServerId == nil)
    #expect(defaults.lastProjectId(forServer: "remote-a") == projectId)
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectId))
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(defaults.configSelections(forHarness: "codex", model: nil) == ["model": "gpt-5.6"])
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == data)
  }

  @Test("Migrates V3 while retaining its machine defaults")
  func migratesV3() throws {
    let current =
      #"{"machines":{"local":{"lastHarnessId":"codex","lastRunLocation":"newWorktree","configSelections":{"codex":{"model":"newer-model"}}}},"version":3}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(current.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "codex")
    #expect(defaults.configSelections(forHarness: "codex", model: nil) == ["model": "newer-model"])
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 7)
  }

  @Test("Migrates scoped V2 data, merging machines in a stable order")
  func migratesScopedV2() throws {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"codex":{"model":"gpt-5.6","effort":"xhigh","speed":"standard"}}},"remote-a":{"lastHarnessId":"codex","runInWorktree":false,"configSelections":{"codex":{"model":"remote-model","effort":"medium"}}}},"workspaces":{"00000000-0000-0000-0000-000000000001":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"older-workspace-model","speed":"fast"}}}}}"#
    let legacyData = Data(legacy.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": legacyData])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(
      defaults.configSelections(forHarness: "claude-code", model: "opus") == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(defaults.configSelections(forHarness: "codex", model: nil) == ["model": "gpt-5.6"])
    #expect(
      defaults.configSelections(forHarness: "codex", model: "gpt-5.6") == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "standard",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", model: "remote-model") == [
        "model": "remote-model", "effort": "medium",
      ])
    #expect(defaults.configSelections(forHarness: "codex", model: "older-workspace-model").isEmpty)
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == legacyData)

    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 7)
    #expect(object["workspaces"] == nil)
    let machines = try #require(object["machines"] as? [String: Any])
    let local = try #require(machines["local"] as? [String: Any])
    #expect(local["runInWorktree"] == nil)
  }

  @Test("A V2 migration is idempotent and keeps its original backup")
  func migrationIsIdempotent() {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"codex","runInWorktree":false,"configSelections":{"codex":{"model":"gpt-5.6"}}}},"workspaces":{}}"#
    let legacyData = Data(legacy.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": legacyData])

    _ = ComposerDefaultsStore(store: store)
    let migrated = store.loadData(forKey: "composer-defaults")
    _ = ComposerDefaultsStore(store: store)

    #expect(store.loadData(forKey: "composer-defaults") == migrated)
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == legacyData)
  }

  @Test("Migrates the pre-workspace machines-only format")
  func migratesMachinesOnlyFormat() {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","speed":"fast"}}}}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(defaults.configSelections(forHarness: "claude-code", model: "opus") == ["model": "opus", "speed": "fast"])
  }

  @Test("Migrates the flat pre-machine format, keeping settings of harnesses without a model")
  func migratesFlatFormat() {
    let legacy =
      #"{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"agent":{"effort":"low"}}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", model: "opus") == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(defaults.configSelections(forHarness: "agent", model: nil) == ["effort": "low"])
  }

  @Test("Migrates a partial flat payload that only remembered run location")
  func migratesPartialFlatPayload() throws {
    let legacy = #"{"runInWorktree":true}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 7)
  }
}
