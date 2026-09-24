import Foundation
import Testing

@testable import CodevisorCore

/// The one-time move from the old storage, where the device kept editable
/// copies of workspaces, chats, and projects, to the navigation store.
@MainActor
@Suite("Navigation store migration")
struct NavigationStoreMigrationTests {
  /// The fields the old "workspaces" payload stored for each workspace.
  private struct LegacyWorkspace: Encodable {
    var id = UUID()
    var name = "Workspace"
    var hasCustomName = false
    var serverId = "local"
    var projectId = UUID()
    var centerTabs: [WorkspaceTab]
    var selectedCenterTabId: UUID?
    var createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    var isServerSynced: Bool?
  }

  private struct LegacyPayload: Encodable {
    var version = 3
    var workspaces: [LegacyWorkspace]
    var sessionIndex: [String: String] = [:]
  }

  private func tabs(_ count: Int) -> [WorkspaceTab] {
    (0..<count).map { _ in WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID()))) }
  }

  private func legacyStore(_ workspaces: [LegacyWorkspace]) throws -> InMemoryStore {
    let store = InMemoryStore()
    var index: [String: String] = [:]
    for workspace in workspaces {
      for tab in workspace.centerTabs {
        for group in tab.root.allGroups {
          for pane in group.state.panes {
            if let chat = pane.chatSessionId { index[chat.uuidString] = workspace.id.uuidString }
          }
        }
      }
    }
    try store.saveData(
      JSONEncoder().encode(LegacyPayload(workspaces: workspaces, sessionIndex: index)), forKey: "workspaces")
    return store
  }

  private static let legacyKeys = [
    "workspaces", "projects", "sessions", "pending-server-sessions-v1", "pending-server-projects-v1",
    "pending-archived-sessions-v1",
  ]

  @Test("Synced workspaces keep their tab arrangement; device-only ones are dropped")
  func migratesSyncedLayouts() throws {
    let synced = LegacyWorkspace(
      serverId: "remote-a", centerTabs: tabs(3), selectedCenterTabId: nil, isServerSynced: true)
    var selected = LegacyWorkspace(serverId: "local", centerTabs: tabs(2), isServerSynced: true)
    selected.selectedCenterTabId = selected.centerTabs[1].id
    let unsynced = LegacyWorkspace(centerTabs: tabs(1), isServerSynced: false)
    let predatesFlag = LegacyWorkspace(centerTabs: tabs(1), isServerSynced: nil)
    let store = try legacyStore([synced, selected, unsynced, predatesFlag])

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local", "remote-a"])

    let layouts = DeviceLayoutStore(store: store)
    let migrated = try #require(layouts.layout(for: synced.id))
    #expect(migrated.serverId == "remote-a")
    #expect(migrated.tabs == synced.centerTabs)
    // No stored selection: the first tab.
    #expect(migrated.selectedTabId == synced.centerTabs[0].id)
    let withSelection = try #require(layouts.layout(for: selected.id))
    #expect(withSelection.serverId == "local")
    #expect(withSelection.tabs == selected.centerTabs)
    #expect(withSelection.selectedTabId == selected.centerTabs[1].id)
    #expect(layouts.layout(for: unsynced.id) == nil)
    #expect(layouts.layout(for: predatesFlag.id) == nil)
    #expect(layouts.drafts.isEmpty)
  }

  @Test("A selection that names a missing tab falls back to the first tab")
  func staleSelectionFallsBack() throws {
    var workspace = LegacyWorkspace(centerTabs: tabs(2), isServerSynced: true)
    workspace.selectedCenterTabId = UUID()
    let store = try legacyStore([workspace])

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])

    #expect(DeviceLayoutStore(store: store).layout(for: workspace.id)?.selectedTabId == workspace.centerTabs[0].id)
  }

  @Test("Every legacy key goes, including each machine's server-authority marker, and a receipt is written")
  func removesLegacyKeys() throws {
    let store = try legacyStore([LegacyWorkspace(centerTabs: tabs(1), isServerSynced: true)])
    for key in Self.legacyKeys where key != "workspaces" {
      try store.saveData(Data("[]".utf8), forKey: key)
    }
    let machines = ["local", "cloud:device-1", "studio.tail.ts.net-443"]
    let authorityKeys = [
      "server-authority-v1-local", "server-authority-v1-cloud-device-1", "server-authority-v1-studio-tail-ts-net-443",
    ]
    for key in authorityKeys { try store.saveData(Data("1".utf8), forKey: key) }
    try store.saveData(Data("keep".utf8), forKey: "settings")

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: machines)

    for key in Self.legacyKeys + authorityKeys {
      #expect(store.loadData(forKey: key) == nil, "\(key) should be removed")
    }
    #expect(store.loadData(forKey: NavigationStoreMigration.receiptKey) != nil)
    // Unrelated data is untouched.
    #expect(store.loadData(forKey: "settings") == Data("keep".utf8))
  }

  @Test("The migration runs once: later legacy data is left alone")
  func runsOnce() throws {
    let first = LegacyWorkspace(centerTabs: tabs(1), isServerSynced: true)
    let store = try legacyStore([first])
    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])
    #expect(DeviceLayoutStore(store: store).layout(for: first.id) != nil)

    // An older build writes the old format again after the upgrade.
    let second = LegacyWorkspace(centerTabs: tabs(2), isServerSynced: true)
    let rewritten = try legacyStore([second]).loadData(forKey: "workspaces")!
    try store.saveData(rewritten, forKey: "workspaces")
    try store.saveData(Data("1".utf8), forKey: "server-authority-v1-local")

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])

    #expect(DeviceLayoutStore(store: store).layout(for: second.id) == nil)
    #expect(DeviceLayoutStore(store: store).layout(for: first.id) != nil)
    #expect(store.loadData(forKey: "workspaces") == rewritten)
    #expect(store.loadData(forKey: "server-authority-v1-local") != nil)
  }

  @Test("A malformed payload is dropped without failing the upgrade")
  func toleratesMalformedPayload() throws {
    let store = InMemoryStore()
    try store.saveData(Data("not json".utf8), forKey: "workspaces")
    try store.saveData(Data("also not json".utf8), forKey: "sessions")

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])

    #expect(store.loadData(forKey: "workspaces") == nil)
    #expect(store.loadData(forKey: "sessions") == nil)
    #expect(store.loadData(forKey: NavigationStoreMigration.receiptKey) != nil)
    #expect(DeviceLayoutStore(store: store).drafts.isEmpty)
  }

  @Test("One unreadable workspace doesn't cost the others their layouts")
  func toleratesMalformedEntry() throws {
    let good = LegacyWorkspace(centerTabs: tabs(2), isServerSynced: true)
    let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
    let payload: [String: Any] = [
      "version": 3,
      "workspaces": [["id": "not-a-uuid", "serverId": 7], goodJSON],
      "sessionIndex": [:] as [String: String],
    ]
    let store = InMemoryStore()
    try store.saveData(JSONSerialization.data(withJSONObject: payload), forKey: "workspaces")

    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])

    #expect(DeviceLayoutStore(store: store).layout(for: good.id)?.tabs == good.centerTabs)
    #expect(store.loadData(forKey: "workspaces") == nil)
  }

  @Test("A fresh install writes only the receipt")
  func freshInstall() {
    let store = InMemoryStore()
    NavigationStoreMigration.runIfNeeded(store: store, machineIds: ["local"])
    #expect(store.loadData(forKey: NavigationStoreMigration.receiptKey) != nil)
    #expect(store.loadData(forKey: DeviceLayoutStore.storageKey) == nil)
  }

  @Test("A migrated layout is what the workspace shows once its machine's snapshot arrives")
  func migratedLayoutAppliesToServerWorkspace() async throws {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/migrated"))
    let chats = [
      ChatSession(projectId: project.id, harnessId: "codex", title: "One"),
      ChatSession(projectId: project.id, harnessId: "codex", title: "Two"),
    ]
    let arranged = chats.map { WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0.id))) }
    let legacy = LegacyWorkspace(
      projectId: project.id, centerTabs: arranged, selectedCenterTabId: arranged[1].id, isServerSynced: true)
    let store = try legacyStore([legacy])

    // The environment runs the migration before it opens the store.
    let environment = AppEnvironment(
      navigationPersistence: store,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore())
    )
    #expect(store.loadData(forKey: "workspaces") == nil)

    // The server's copy of the same workspace, as its first sync delivers it.
    let server = Workspace(
      id: legacy.id, name: "Server name", rootDirectory: nil, serverId: "local", projectId: project.id,
      centerTabs: arranged, createdAt: legacy.createdAt, isServerSynced: true)
    await environment.navigationStore.replace(
      .fixture(projects: [project], sessions: chats, workspaces: [server]), machineId: "local", requestedAt: Date())

    let shown = try #require(environment.workspaces.workspace(id: legacy.id))
    #expect(shown.name == "Server name")
    #expect(shown.centerTabs.map(\.id) == arranged.map(\.id))
    #expect(shown.selectedCenterTabId == arranged[1].id)
  }
}
