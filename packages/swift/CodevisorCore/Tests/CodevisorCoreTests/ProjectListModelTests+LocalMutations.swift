import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
  @Test("Local mutations are sent to the record's machine")
  func serverMutationMirroring() async throws {
    let fakeServer = FakeServerClient()
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/mirrored"))
    let session = model.newSession(in: project, title: "First", harnessId: "codex")
    await fixture.sync(with: fakeServer)
    model.renameSession(session, to: "Renamed")
    await fixture.sync(with: fakeServer)
    #expect(fixture.session(session.id)?.title == "Renamed")
    model.deleteSession(session)
    model.removeProject(project)
    await fixture.sync(with: fakeServer)

    let snapshot = await fakeServer.snapshot()
    #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
    // The create, then the rename (sent as an upsert by this fake).
    #expect(snapshot.upsertedSessionIDs == [session.id.uuidString, session.id.uuidString])
    #expect(snapshot.deletedSessionIDs == [session.id.uuidString])
    #expect(snapshot.deletedProjectIDs == [project.id.uuidString])
    #expect(model.projects.isEmpty)
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("Draft sessions are held locally until first send")
  func draftSessionSkipsImmediateServerSync() async throws {
    let fakeServer = FakeServerClient()
    let fixture = await NavigationFixture.connected(to: fakeServer)
    let model = fixture.projectList

    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/draft"))
    let draft = model.newSession(in: project, title: "Draft", harnessId: "codex", syncToServer: false)
    await fixture.flush()

    let snapshot = await fakeServer.snapshot()
    #expect(snapshot.upsertedProjectIDs == [project.id.uuidString])
    #expect(snapshot.upsertedSessionIDs.isEmpty)
    #expect(model.sessions.contains { $0.id == draft.id })
  }

  @Test("Adding a folder creates a project that survives a relaunch")
  func addProject() {
    let persistence = InMemoryStore()
    let model = NavigationFixture(persistence: persistence).projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/proj"))
    #expect(project.name == "proj")
    #expect(model.projects.count == 1)
    // The waiting request is saved: a fresh store reads it back.
    PersistenceEncoding.drain()
    #expect(NavigationFixture(persistence: persistence).projectList.projects.count == 1)
  }

  @Test("Adding the same folder twice does not duplicate")
  func addDeduplicates() {
    let model = NavigationFixture().projectList
    let url = URL(fileURLWithPath: "/tmp/proj")
    let first = model.addProject(folderURL: url)
    let second = model.addProject(folderURL: url)
    #expect(model.projects.count == 1)
    #expect(second.id == first.id)
  }

  @Test("Deleting a project removes it from the active list")
  func deletingRemovesFromActiveList() {
    let model = NavigationFixture().projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
    #expect(model.activeProjects.count == 1)

    // Projects are deleted rather than archived: there is no hidden section
    // they can fall into and be recovered from.
    model.removeProject(project)
    #expect(model.activeProjects.isEmpty)
    #expect(model.isProjectDeleted(id: project.id, serverId: project.serverId))
  }

  @Test("Active projects are sorted newest-first")
  func sorting() async {
    let fixture = NavigationFixture()
    await fixture.install(projects: [
      Project.fromFolder(URL(fileURLWithPath: "/tmp/old"), createdAt: Date(timeIntervalSince1970: 1)),
      Project.fromFolder(URL(fileURLWithPath: "/tmp/new"), createdAt: Date(timeIntervalSince1970: 9)),
    ])
    #expect(fixture.projectList.activeProjects.map(\.name) == ["new", "old"])
  }

  @Test("New sessions are scoped to a project and survive a relaunch")
  func sessions() {
    let persistence = InMemoryStore()
    let model = NavigationFixture(persistence: persistence).projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
    let other = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/b"))
    let session = model.newSession(in: project, title: "First", harnessId: "claude")
    model.newSession(in: other)
    #expect(model.sessions(in: project).map(\.id) == [session.id])

    PersistenceEncoding.drain()
    #expect(NavigationFixture(persistence: persistence).projectList.sessions.count == 2)
  }

  @Test("Renaming and deleting sessions show immediately")
  func renameDelete() async {
    let fixture = NavigationFixture()
    let model = fixture.projectList
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/a"))
    let session = ChatSession(projectId: project.id, harnessId: "codex")
    await fixture.install(projects: [project], sessions: [session])

    model.renameSession(session, to: "Renamed")
    #expect(model.sessions(in: project).first?.title == "Renamed")
    model.deleteSession(session)
    #expect(model.sessions(in: project).isEmpty)
  }

  @Test("Removing a project also removes its sessions")
  func removeProject() {
    let model = NavigationFixture().projectList
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
    model.newSession(in: project)
    model.removeProject(project)
    #expect(model.projects.isEmpty)
    #expect(model.sessions.isEmpty)
  }

  @Test("Importing sessions into a project skips known ones")
  func importIntoProject() {
    let persistence = InMemoryStore()
    let model = NavigationFixture(persistence: persistence).projectList
    model.showsImportedSessions = true
    let project = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
    let imported = [
      ImportedSession(
        harnessId: "claude-code",
        info: SessionInfo(
          sessionId: "ext-1", cwd: "/tmp/a", title: "Old chat", updatedAt: "2026-06-01T00:00:00Z")
      ),
      ImportedSession(
        harnessId: "claude-code",
        info: SessionInfo(sessionId: "ext-2", cwd: "/tmp/a")
      ),
    ]

    model.importSessions(imported, into: project)
    // Importing the same discoveries again must not duplicate anything.
    model.importSessions(imported, into: project)

    let sessions = model.sessions(in: project)
    #expect(sessions.count == 2)
    #expect(sessions.allSatisfy { $0.origin == .imported })
    #expect(sessions.contains { $0.agentSessionId == "ext-1" && $0.title == "Old chat" })
    #expect(sessions.contains { $0.agentSessionId == "ext-2" && $0.title == "Session" })
    PersistenceEncoding.drain()
    #expect(NavigationFixture(persistence: persistence).projectList.sessions.count == 2)
  }

  @Test("Re-importing a known session advances its activity without overwriting metadata")
  func reimportAdvancesKnownSessionActivity() async {
    let fixture = NavigationFixture()
    let model = fixture.projectList
    model.showsImportedSessions = true
    let oldTimestamp = "2026-06-01T00:00:00Z"
    // Native scanners return JavaScript ISO strings with fractional
    // seconds, so exercise the exact format used by the server endpoint.
    let newTimestamp = "2026-06-03T00:00:00.123Z"
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/a"), origin: .imported)
    // The server already has this import, with a title the user edited.
    let known = ChatSession(
      projectId: project.id, harnessId: "codex", agentSessionId: "ext-1", title: "My title",
      origin: .imported, createdAt: ISO8601DateFormatter().date(from: oldTimestamp)!,
      updatedAt: ISO8601DateFormatter().date(from: oldTimestamp))
    await fixture.install(projects: [project], sessions: [known])

    model.importSessions(
      [
        ImportedSession(
          harnessId: "codex",
          info: SessionInfo(
            sessionId: "ext-1", cwd: "/tmp/a", title: "Changed agent title", updatedAt: newTimestamp)
        )
      ], serverId: "local")

    let refreshed = model.sessions(in: project).first!
    #expect(model.sessions.count == 1)
    #expect(refreshed.title == "My title")
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(refreshed.updatedAt == fractionalFormatter.date(from: newTimestamp))
    // The advance is a waiting upsert of the known record.
    guard case let .upsertSession(sent, _)? = fixture.store.pendingIntents.last?.intent else {
      Issue.record("Expected a waiting upsert")
      return
    }
    #expect(sent.id == known.id)
    #expect(sent.updatedAt == refreshed.updatedAt)

    // An older scanner result must never roll server/app activity back.
    model.importSessions(
      [
        ImportedSession(
          harnessId: "codex",
          info: SessionInfo(sessionId: "ext-1", cwd: "/tmp/a", updatedAt: oldTimestamp)
        )
      ], serverId: "local")
    #expect(model.sessions(in: project).first?.updatedAt == refreshed.updatedAt)
  }
}
