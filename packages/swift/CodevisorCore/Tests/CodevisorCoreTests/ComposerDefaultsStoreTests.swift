import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("ComposerDefaultsStore")
struct ComposerDefaultsStoreTests {
  @Test("Starts empty")
  func startsEmpty() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    #expect(defaults.lastNewWorkspaceServerId == nil)
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)
    #expect(defaults.lastProjectId(forServer: "local") == nil)
    #expect(defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")).isEmpty)
  }

  @Test("An explicit harness selection is remembered immediately")
  func remembersHarnessImmediately() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)

    defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(ComposerDefaultsStore(store: store).lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
  }

  @Test("The worktree choice is remembered per project, falling back to the machine's legacy choice")
  func remembersWorktreeChoicePerProject() throws {
    let projectA = UUID()
    let projectB = UUID()
    let legacy =
      #"{"machines":{"local":{"newWorkspaceInWorktree":true,"configSelections":{}}},"version":5,"workspaces":{}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])
    let defaults = ComposerDefaultsStore(store: store)
    // No project record yet: the legacy machine-wide choice applies.
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "local", projectId: projectA))
    #expect(!defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectA))

    defaults.rememberNewWorkspaceWorktreePreference(
      serverId: "local",
      projectId: projectA,
      createsWorktree: false
    )

    let reopened = ComposerDefaultsStore(store: store)
    #expect(!reopened.prefersWorktreeForNewWorkspaces(forServer: "local", projectId: projectA))
    // Another project keeps the fallback rather than A's choice.
    #expect(reopened.prefersWorktreeForNewWorkspaces(forServer: "local", projectId: projectB))
  }

  @Test("The standalone New Chat project is remembered per machine")
  func remembersNewWorkspaceProject() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)
    let localProject = UUID()
    let remoteProject = UUID()

    defaults.rememberNewWorkspaceProject(serverId: "local", projectId: localProject)
    defaults.rememberNewWorkspaceProject(serverId: "remote-a", projectId: remoteProject)

    let reopened = ComposerDefaultsStore(store: store)
    #expect(reopened.lastNewWorkspaceServerId == "remote-a")
    #expect(reopened.lastProjectId(forServer: "local") == localProject)
    #expect(reopened.lastProjectId(forServer: "remote-a") == remoteProject)
  }

  @Test("The standalone New Chat machine can be remembered without a project")
  func remembersNewWorkspaceMachine() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)

    defaults.rememberNewWorkspaceServer(serverId: "remote-empty")

    let reopened = ComposerDefaultsStore(store: store)
    #expect(reopened.lastNewWorkspaceServerId == "remote-empty")
    #expect(reopened.lastProjectId(forServer: "remote-empty") == nil)
  }

  @Test("Keeps every harness configuration independent")
  func perHarnessSelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "claude-code",
      configValues: ["model": "opus", "effort": "high", "speed": "fast"]
    )
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "standard"]
    )

    #expect(
      defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")) == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "standard",
      ])
  }

  @Test("Partial option updates retain temporarily unavailable values")
  func mergesConfigSelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.6", "effort": "high", "speed": "fast"]
    )
    // A model without a speed picker reports only its currently available
    // values. The prior speed preference should still be there if the user
    // switches back to a fast-capable model later.
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.5", "effort": "medium"]
    )

    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "gpt-5.5", "effort": "medium", "speed": "fast",
      ])
  }

  @Test("Invalid empty selections do not erase existing defaults")
  func ignoresEmptySelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"), harnessId: "claude-code", configValues: ["model": "opus"]
    )

    defaults.rememberHarnessSelection(serverId: "local", harnessId: nil)
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"), harnessId: "claude-code", configValues: [:]
    )

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")) == [
        "model": "opus"
      ])
  }

  @Test("Migrates scoped V2 data without losing machine configuration")
  func migratesScopedV2() throws {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"codex":{"model":"gpt-5.6","effort":"xhigh","speed":"standard"}}},"remote-a":{"lastHarnessId":"codex","runInWorktree":false,"configSelections":{"codex":{"model":"remote-model","effort":"medium"}}}},"workspaces":{"00000000-0000-0000-0000-000000000001":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"older-workspace-model","speed":"fast"}}}}}"#
    let legacyData = Data(legacy.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": legacyData])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")) == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "standard",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "remote-a")) == [
        "model": "remote-model", "effort": "medium",
      ])
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == legacyData)

    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 6)
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
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == legacyData)
  }

  @Test("Migrates V3 while retaining its machine defaults")
  func migratesV3() throws {
    let current =
      #"{"machines":{"local":{"lastHarnessId":"codex","lastRunLocation":"newWorktree","configSelections":{"codex":{"model":"newer-model"}}}},"version":3}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(current.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "codex")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "newer-model"
      ])
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 6)
  }

  @Test("Migrates the pre-workspace machines-only format")
  func migratesMachinesOnlyFormat() {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","speed":"fast"}}}}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")) == [
        "model": "opus", "speed": "fast",
      ])
  }

  @Test("Migrates the flat pre-machine format to the local machine")
  func migratesFlatFormat() {
    let legacy =
      #"{"lastHarnessId":"claude-code","runInWorktree":true,"configSelections":{"claude-code":{"model":"opus","effort":"high","speed":"fast"},"codex":{"model":"gpt-5.6"}}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "local")) == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "gpt-5.6"
      ])
  }

  @Test("Migrates a partial flat payload that only remembered run location")
  func migratesPartialFlatPayload() throws {
    let legacy = #"{"runInWorktree":true}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 6)
  }

  @Test("Migrates V4 keeping machine defaults and dropping workspace profiles")
  func migratesV4() throws {
    let projectId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let version4 =
      #"{"machines":{"remote-a":{"lastHarnessId":"codex","lastProjectId":"00000000-0000-0000-0000-000000000002","newWorkspaceInWorktree":true,"configSelections":{"codex":{"model":"gpt-5.6"}}}},"version":4,"workspaces":{"00000000-0000-0000-0000-000000000003":{"serverId":"remote-a","lastHarnessId":"claude-code","configSelections":{"claude-code":{"model":"opus"}}}}}"#
    let data = Data(version4.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": data])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastNewWorkspaceServerId == nil)
    #expect(defaults.lastProjectId(forServer: "remote-a") == projectId)
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectId))
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == data)
  }

  @Test("Migrates V5: machine defaults survive, workspace profiles are dropped")
  func migratesV5() throws {
    let projectId = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let version5 =
      #"{"lastNewWorkspaceServerId":"remote-a","machines":{"remote-a":{"lastHarnessId":"codex","lastProjectId":"00000000-0000-0000-0000-000000000002","newWorkspaceInWorktree":true,"configSelections":{"codex":{"model":"gpt-5.6","effort":"high"}}}},"version":5,"workspaces":{"00000000-0000-0000-0000-000000000003":{"serverId":"remote-a","lastHarnessId":"claude-code","configSelections":{"claude-code":{"model":"opus"}}}}}"#
    let data = Data(version5.utf8)
    let store = InMemoryStore(storage: ["composer-defaults": data])

    let defaults = ComposerDefaultsStore(store: store)

    #expect(defaults.lastNewWorkspaceServerId == "remote-a")
    #expect(defaults.lastProjectId(forServer: "remote-a") == projectId)
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "remote-a")) == [
        "model": "gpt-5.6", "effort": "high",
      ])
    // The workspace's last-focused chat no longer leaks into anything.
    #expect(defaults.configSelections(forHarness: "claude-code", in: .newWorkspace(serverId: "remote-a")).isEmpty)
    // Projects without their own record fall back to the legacy choice.
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectId))
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == data)
    let migrated = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    #expect(object["version"] as? Int == 6)
    #expect(object["workspaces"] == nil)
  }

  @Test("Persists the V6 format across instances without creating a migration backup")
  func persistsCurrentFormat() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "codex")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "codex",
      configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "fast"]
    )

    let reopened = ComposerDefaultsStore(store: store)

    #expect(reopened.lastHarnessId(for: .newWorkspace(serverId: "local")) == "codex")
    #expect(
      reopened.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")) == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "fast",
      ])
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == nil)
  }

  @Test("Clear resets active defaults and removes the migration backup")
  func clears() {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"gpt-5.6"}}}},"workspaces":{}}"#
    let store = InMemoryStore(storage: ["composer-defaults": Data(legacy.utf8)])
    let defaults = ComposerDefaultsStore(store: store)
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") != nil)

    defaults.clear()

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)
    #expect(defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "local")).isEmpty)
    #expect(defaults.lastNewWorkspaceServerId == nil)
    #expect(store.loadData(forKey: "composer-defaults-pre-v6-backup") == nil)
    #expect(store.loadData(forKey: "composer-defaults-pre-v5-backup") == nil)
    #expect(store.loadData(forKey: "composer-defaults-pre-v4-backup") == nil)
    #expect(store.loadData(forKey: "composer-defaults-pre-v3-backup") == nil)
  }

  @Test("Corrupted data decodes as empty and is quarantined, not overwritten")
  func corrupted() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("nope".utf8).write(to: directory.appendingPathComponent("composer-defaults.json"))

    let defaults = ComposerDefaultsStore(store: FileSystemStore(directory: directory))
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!contents.contains("composer-defaults.json"))
    #expect(contents.contains { $0.hasPrefix("composer-defaults.json.corrupt-") })
  }

  /// Schema tripwire: changing this string requires a decoder fixture for
  /// this exact V6 shape before the golden value is updated.
  @Test("Persisted wire format is stable — schema changes require a migration")
  func wireFormatIsStable() throws {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")
    defaults.rememberNewWorkspaceProject(
      serverId: "local",
      projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    )
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "local"),
      harnessId: "claude-code",
      configValues: ["model": "opus", "effort": "high"]
    )
    defaults.rememberNewWorkspaceWorktreePreference(
      serverId: "local",
      projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      createsWorktree: true
    )
    defaults.flushPendingWrites()
    let data = try #require(store.loadData(forKey: "composer-defaults"))
    let object = try JSONSerialization.jsonObject(with: data)
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(
      String(decoding: canonical, as: UTF8.self)
        == #"{"lastNewWorkspaceServerId":"local","machines":{"local":{"configSelections":{"claude-code":{"effort":"high","model":"opus"}},"lastHarnessId":"claude-code","lastProjectId":"00000000-0000-0000-0000-000000000004","worktreeByProject":{"00000000-0000-0000-0000-000000000004":true}}},"version":6}"#
    )
  }

  @Test("Never shares composer choices between machines")
  func machineIsolation() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "remote-a", harnessId: "codex")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "remote-a"), harnessId: "codex", configValues: ["model": "model-a"]
    )
    defaults.rememberHarnessSelection(serverId: "remote-b", harnessId: "claude-code")
    defaults.rememberConfigSelections(
      in: .newWorkspace(serverId: "remote-b"), harnessId: "claude-code", configValues: ["model": "model-b"]
    )

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-b")) == "claude-code")
    #expect(
      defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "remote-a")) == [
        "model": "model-a"
      ])
    #expect(defaults.configSelections(forHarness: "codex", in: .newWorkspace(serverId: "remote-b")).isEmpty)
  }
}
