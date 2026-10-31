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

  @Test("An event for a machine with nothing cached asks for a snapshot")
  func deltaWithoutCache() async {
    let fixture = NavigationFixture()
    let delta = ServerNavigationDelta.fixture(cursor: 5)
    #expect(await fixture.store.apply(delta, machineId: "m") == false)
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
