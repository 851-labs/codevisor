import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
struct NavigationProjectionTests {
  let project = Project.fromFolder(URL(fileURLWithPath: "/src/app"), serverId: "m")

  func workspace(
    chat: ChatSession, on serverId: String = "m", id: UUID = UUID(), createdAt: Date = Date()
  ) -> Workspace {
    Workspace(
      id: id, name: "W", rootDirectory: "/src/app", serverId: serverId, projectId: project.id,
      centerTree: .leaf(.centerInitial(sessionId: chat.id, paneId: chat.id)), createdAt: createdAt,
      isServerSynced: true)
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
  func cacheSurvivesRelaunch() async throws {
    let persistence = InMemoryStore()
    let cacheFixture = try ClientCacheFixture()
    defer { cacheFixture.tearDown() }
    let cache = try cacheFixture.makeCache()
    let chat = ChatSession(projectId: project.id, serverId: "m", title: "Fix it")
    let first = NavigationFixture(persistence: persistence, clientCache: cache)
    await first.install(machineId: "m", projects: [project], sessions: [chat], workspaces: [workspace(chat: chat)])
    PersistenceEncoding.drain()
    await cache.flush()

    let relaunched = NavigationFixture(persistence: persistence, clientCache: try cacheFixture.makeCache())
    #expect(relaunched.store.hasCache(for: "m"))
    #expect(relaunched.projectList.sessions.map(\.id) == [chat.id])
    #expect(relaunched.workspaces.loadAll().count == 1)
    relaunched.store.forget(machineId: "m")
    #expect(relaunched.projectList.sessions.isEmpty)
    #expect(!relaunched.store.hasCache(for: "m"))
  }

  @Test(
    "A workspace that moved to another machine shows once, on the machine that took it last, with that machine's chats")
  func movedWorkspace() async {
    let old = ChatSession(projectId: project.id, serverId: "sandbox-old", title: "Fix it")
    var moved = old
    moved.serverId = "sandbox-new"
    let before = workspace(chat: old, on: "sandbox-old", createdAt: Date(timeIntervalSince1970: 100))
    var standIn = Workspace(
      id: before.id, name: "W", rootDirectory: nil, serverId: "mac", projectId: project.id,
      centerTabs: [.placeholder()], createdAt: Date(timeIntervalSince1970: 200), isArchived: true,
      isServerSynced: true)
    standIn.archivedAt = standIn.createdAt
    let after = workspace(chat: moved, on: "sandbox-new", id: before.id, createdAt: Date(timeIntervalSince1970: 300))
    let fixture = NavigationFixture()

    await fixture.install(machineId: "sandbox-old", projects: [project], sessions: [old], workspaces: [before])
    await fixture.install(machineId: "mac", projects: [project], workspaces: [standIn])
    let archived = fixture.workspaces.loadAll().map { [$0.serverId, $0.isArchived ? "archived" : "active"] }
    await fixture.install(machineId: "sandbox-new", projects: [project], sessions: [moved], workspaces: [after])

    #expect(archived == [["mac", "archived"]])
    #expect(fixture.workspaces.loadAll().map(\.serverId) == ["sandbox-new"])
    #expect(fixture.workspaces.workspace(id: before.id)?.chatSessionIds == [moved.id])
    #expect(fixture.projectList.sessions.map(\.serverId) == ["sandbox-new"])
    #expect(fixture.store.workspaceEntries.sidebar.map(\.serverId) == ["sandbox-new"])
    #expect(fixture.store.workspaceEntries.archived.isEmpty)
  }

  @Test("A machine that stops listing a moved workspace gives it back to the one still holding it")
  func ownerLeaves() async {
    let chat = ChatSession(projectId: project.id, serverId: "sandbox", title: "Fix it")
    let live = workspace(chat: chat, on: "sandbox", createdAt: Date(timeIntervalSince1970: 100))
    let standIn = Workspace(
      id: live.id, name: "W", rootDirectory: nil, serverId: "mac", projectId: project.id,
      centerTabs: [.placeholder()], createdAt: Date(timeIntervalSince1970: 200), isArchived: true,
      isServerSynced: true)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "sandbox", projects: [project], sessions: [chat], workspaces: [live])
    await fixture.install(machineId: "mac", projects: [project], workspaces: [standIn])

    await fixture.install(machineId: "mac", projects: [project], workspaces: [], cursor: 2)

    #expect(fixture.workspaces.loadAll().map(\.serverId) == ["sandbox"])
    #expect(fixture.projectList.sessions.map(\.id) == [chat.id])
  }

  @Test("A workspace being restored shows as restoring from the click until its new sandbox lists it, with no gap")
  func restoring() async {
    let chat = ChatSession(projectId: project.id, serverId: "sandbox", title: "Fix it")
    let standIn = Workspace(
      name: "W", rootDirectory: nil, serverId: "mac", projectId: project.id, centerTabs: [.placeholder()],
      createdAt: Date(timeIntervalSince1970: 200), isServerSynced: true)
    let restored = workspace(chat: chat, on: "sandbox", id: standIn.id, createdAt: Date(timeIntervalSince1970: 300))
    let fixture = NavigationFixture()
    func shown() -> [String] {
      fixture.store.workspaceEntries.sidebar.map { "\($0.serverId) \($0.isRestoring ? "restoring" : "ready")" }
    }

    await fixture.install(machineId: "mac", projects: [project], workspaces: [standIn])
    fixture.store.setRestoring([
      standIn.id: RestoringWorkspace(sandboxId: "s", vendorId: "apple-container", sandboxMachineId: nil)
    ])
    let started = shown()
    fixture.store.setRestoring([
      standIn.id: RestoringWorkspace(sandboxId: "s", vendorId: "apple-container", sandboxMachineId: "sandbox")
    ])
    await fixture.install(machineId: "mac", projects: [project], workspaces: [], cursor: 2)
    let handedOver = shown()
    await fixture.install(machineId: "sandbox", projects: [project], sessions: [chat], workspaces: [restored])

    #expect(started == ["mac restoring"])
    #expect(handedOver == ["mac restoring"])
    #expect(shown() == ["sandbox ready"])
    #expect(fixture.workspaces.workspace(id: standIn.id)?.chatSessionIds == [chat.id])
  }

  @Test("A restore that fails stops showing as restoring and goes back under Archived")
  func restoreFailed() async {
    var standIn = Workspace(
      name: "W", rootDirectory: nil, serverId: "mac", projectId: project.id, centerTabs: [.placeholder()],
      createdAt: Date(timeIntervalSince1970: 200), isServerSynced: true)
    let fixture = NavigationFixture()
    await fixture.install(machineId: "mac", projects: [project], workspaces: [standIn])
    fixture.store.setRestoring([
      standIn.id: RestoringWorkspace(sandboxId: "s", vendorId: "apple-container", sandboxMachineId: nil)
    ])

    standIn.isArchived = true
    standIn.archivedAt = standIn.createdAt
    await fixture.install(machineId: "mac", projects: [project], workspaces: [standIn], cursor: 2)
    fixture.store.setRestoring([:])

    #expect(fixture.store.workspaceEntries.sidebar.isEmpty)
    #expect(fixture.store.workspaceEntries.archived.map(\.isRestoring) == [false])
  }
}
