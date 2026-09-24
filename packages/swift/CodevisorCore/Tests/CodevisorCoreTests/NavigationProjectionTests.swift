import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationProjectionTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")

  func workspace(chat: ChatSession) -> Workspace {
    Workspace(
      name: "W", rootDirectory: "/src/app", serverId: "m", projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id, paneId: chat.id)), isServerSynced: true)
  }

  @Test("What shows is the server's state with this device's layout, and tab identities stay stable")
  func stableLayout() async {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [workspace(chat: chat)])
    let shown = try! #require(fixture.workspaces.loadAll().first)
    #expect(shown.chatSessionIds == [chat.id])
    #expect(fixture.workspaces.workspaceId(forSession: chat.id) == shown.id)
    #expect(fixture.projectList.sessions.map(\.id) == [chat.id])

    fixture.store.rebuild()
    #expect(fixture.workspaces.workspace(id: shown.id)?.centerTabs.map(\.id) == shown.centerTabs.map(\.id))
  }

  @Test("A waiting change shows at once, and a refused one falls back to the server's state")
  func overlayAndRefusal() async {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    let fixture = NavigationFixture()
    let original = workspace(chat: chat)
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [original])
    fixture.store.executor.isMachineReady = { _ in true }
    let refusing = SyncFakeServerClient(projects: [], sessions: [])
    refusing.workspaceRenameHandler = { _, _, _ in throw CodevisorServerClientError.httpStatus(409, "conflict") }
    fixture.store.executor.clientProvider = { _ in refusing }

    fixture.store.enqueue(.renameWorkspace(workspaceId: original.id, name: "Mine", hasCustomName: true), machineId: "m")
    #expect(fixture.workspaces.workspace(id: original.id)?.name == "Mine")
    await fixture.store.executor.idle(machineId: "m")
    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(fixture.workspaces.workspace(id: original.id)?.name == "W")
  }

  @Test("Another device's change arrives as an event and replaces what shows, without touching waiting changes")
  func deltaKeepsPendingChanges() async {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    let fixture = NavigationFixture()
    let original = workspace(chat: chat)
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [original])
    fixture.store.enqueue(
      .renameWorkspace(workspaceId: original.id, name: "Mine", hasCustomName: true), machineId: "m")

    var renamedChat = serverSession(from: chat)
    renamedChat.title = "Renamed elsewhere"
    renamedChat.workspaceId = original.id.uuidString
    let delta = ServerNavigationDelta.fixture(cursor: 5, sessions: [renamedChat])
    #expect(await fixture.store.apply(delta, machineId: "m"))
    #expect(fixture.projectList.sessions.first?.title == "Renamed elsewhere")
    #expect(fixture.workspaces.workspace(id: original.id)?.name == "Mine")
  }

  @Test("An event for a machine with nothing cached asks for a snapshot")
  func deltaWithoutCache() async {
    let fixture = NavigationFixture()
    let delta = ServerNavigationDelta.fixture(cursor: 5)
    #expect(await fixture.store.apply(delta, machineId: "m") == false)
  }

  @Test("A pane deleted on another device leaves this device's layout in one step")
  func paneDeletion() async {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    var original = workspace(chat: chat)
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t1")
    original.upsertCenterPane(terminal)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [original])
    #expect(fixture.workspaces.workspace(id: original.id)?.allPanes.contains { $0.id == terminal.id } == true)

    let delta = ServerNavigationDelta.fixture(
      cursor: 5, deleted: [(table: "workspace_panes", id: terminal.id.uuidString)])
    #expect(await fixture.store.apply(delta, machineId: "m"))
    #expect(fixture.workspaces.workspace(id: original.id)?.allPanes.contains { $0.id == terminal.id } == false)
  }

  @Test("A snapshot older than the cache doesn't undo events already applied")
  func staleSnapshotIgnored() async {
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "New")
    let fixture = NavigationFixture()
    await fixture.install(machineId: "m", projects: [project], sessions: [chat], cursor: 10)
    await fixture.store.replace(
      .fixture(projects: [project], cursor: 5), machineId: "m", requestedAt: Date(), resetsStream: false)
    #expect(fixture.projectList.sessions.map(\.id) == [chat.id])
  }

  @Test("The cache is on disk: the next launch shows it before any network")
  func cacheSurvivesRelaunch() async {
    let persistence = InMemoryStore()
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    let first = NavigationFixture(persistence: persistence)
    await first.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [workspace(chat: chat)])
    PersistenceEncoding.drain()

    let relaunched = NavigationFixture(persistence: persistence)
    #expect(relaunched.store.hasCache(for: "m"))
    #expect(relaunched.projectList.sessions.map(\.id) == [chat.id])
    #expect(relaunched.workspaces.loadAll().count == 1)
    relaunched.store.forget(machineId: "m")
    #expect(relaunched.projectList.sessions.isEmpty)
    #expect(!relaunched.store.hasCache(for: "m"))
  }
}
