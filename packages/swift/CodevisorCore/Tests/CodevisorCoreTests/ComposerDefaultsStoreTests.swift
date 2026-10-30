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
    #expect(defaults.configSelections(forHarness: "claude-code", model: nil).isEmpty)
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
    #expect(defaults.prefersWorktreeForNewWorkspaces(forServer: "local", projectId: projectA))
    #expect(!defaults.prefersWorktreeForNewWorkspaces(forServer: "remote-a", projectId: projectA))

    defaults.rememberNewWorkspaceWorktreePreference(
      serverId: "local",
      projectId: projectA,
      createsWorktree: false
    )

    let reopened = ComposerDefaultsStore(store: store)
    #expect(!reopened.prefersWorktreeForNewWorkspaces(forServer: "local", projectId: projectA))
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
      harnessId: "claude-code",
      modelOptionId: "model",
      configValues: ["model": "opus", "effort": "high", "speed": "fast"]
    )
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "standard"]
    )

    #expect(
      defaults.configSelections(forHarness: "claude-code", model: "opus") == [
        "model": "opus", "effort": "high", "speed": "fast",
      ])
    #expect(
      defaults.configSelections(forHarness: "codex", model: "gpt-5.6") == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "standard",
      ])
  }

  @Test("Each model keeps its own settings while the harness remembers the last model")
  func perModelSelections() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6-sol", "effort": "high", "speed": "fast"]
    )
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.5", "effort": "medium"]
    )

    let reopened = ComposerDefaultsStore(store: store)
    #expect(reopened.configSelections(forHarness: "codex", model: nil) == ["model": "gpt-5.5"])
    #expect(
      reopened.configSelections(forHarness: "codex", model: "gpt-5.5") == ["model": "gpt-5.5", "effort": "medium"])
    #expect(
      reopened.configSelections(forHarness: "codex", model: "gpt-5.6-sol") == [
        "model": "gpt-5.6-sol", "effort": "high", "speed": "fast",
      ])
    #expect(reopened.configSelections(forHarness: "codex", model: "gpt-5.7").isEmpty)
  }

  @Test("Settings are remembered per harness only when the harness has no model option")
  func modelessHarnessSelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())

    defaults.rememberConfigSelections(harnessId: "codex", modelOptionId: "model", configValues: ["speed": "fast"])
    defaults.rememberConfigSelections(harnessId: "agent", modelOptionId: nil, configValues: ["effort": "high"])

    #expect(defaults.configSelections(forHarness: "codex", model: nil).isEmpty)
    #expect(defaults.configSelections(forHarness: "agent", model: nil) == ["effort": "high"])
  }

  @Test("Partial option updates retain temporarily unavailable values")
  func mergesConfigSelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6", "effort": "high", "speed": "fast"]
    )
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6", "effort": "medium"]
    )

    #expect(
      defaults.configSelections(forHarness: "codex", model: "gpt-5.6") == [
        "model": "gpt-5.6", "effort": "medium", "speed": "fast",
      ])
  }

  @Test("Invalid empty selections do not erase existing defaults")
  func ignoresEmptySelections() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "claude-code")
    defaults.rememberConfigSelections(harnessId: "claude-code", modelOptionId: "model", configValues: ["model": "opus"])

    defaults.rememberHarnessSelection(serverId: "local", harnessId: nil)
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "")
    defaults.rememberConfigSelections(harnessId: "claude-code", modelOptionId: "model", configValues: [:])
    defaults.rememberConfigSelections(harnessId: "claude-code", modelOptionId: "model", configValues: ["model": ""])

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == "claude-code")
    #expect(defaults.configSelections(forHarness: "claude-code", model: nil) == ["model": "opus"])
  }

  @Test("Persists the V7 format across instances without creating a migration backup")
  func persistsCurrentFormat() {
    let store = InMemoryStore()
    let defaults = ComposerDefaultsStore(store: store)
    defaults.rememberHarnessSelection(serverId: "local", harnessId: "codex")
    defaults.rememberConfigSelections(
      harnessId: "codex",
      modelOptionId: "model",
      configValues: ["model": "gpt-5.6", "effort": "xhigh", "speed": "fast"]
    )

    let reopened = ComposerDefaultsStore(store: store)

    #expect(reopened.lastHarnessId(for: .newWorkspace(serverId: "local")) == "codex")
    #expect(
      reopened.configSelections(forHarness: "codex", model: "gpt-5.6") == [
        "model": "gpt-5.6", "effort": "xhigh", "speed": "fast",
      ])
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == nil)
  }

  @Test("Clear resets active defaults and removes the migration backups")
  func clears() {
    let legacy =
      #"{"machines":{"local":{"lastHarnessId":"codex","configSelections":{"codex":{"model":"gpt-5.6"}}}},"workspaces":{}}"#
    let store = InMemoryStore(storage: [
      "composer-defaults": Data(legacy.utf8),
      "composer-defaults-pre-v6-backup": Data(legacy.utf8),
    ])
    let defaults = ComposerDefaultsStore(store: store)
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") != nil)

    defaults.clear()

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "local")) == nil)
    #expect(defaults.configSelections(forHarness: "codex", model: nil).isEmpty)
    #expect(defaults.lastNewWorkspaceServerId == nil)
    #expect(store.loadData(forKey: "composer-defaults-pre-v7-backup") == nil)
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
      harnessId: "claude-code",
      modelOptionId: "model",
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
        == #"{"harnesses":{"claude-code":{"values":{"model":"opus"},"valuesByModel":{"opus":{"effort":"high","model":"opus"}}}},"lastNewWorkspaceServerId":"local","machines":{"local":{"lastHarnessId":"claude-code","lastProjectId":"00000000-0000-0000-0000-000000000004","worktreeByProject":{"00000000-0000-0000-0000-000000000004":true}}},"version":7}"#
    )
  }

  @Test("The last harness is remembered per machine")
  func machineScope() {
    let defaults = ComposerDefaultsStore(store: InMemoryStore())
    defaults.rememberHarnessSelection(serverId: "remote-a", harnessId: "codex")
    defaults.rememberHarnessSelection(serverId: "remote-b", harnessId: "claude-code")

    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-a")) == "codex")
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-b")) == "claude-code")
    #expect(defaults.lastHarnessId(for: .newWorkspace(serverId: "remote-c")) == nil)
  }
}
