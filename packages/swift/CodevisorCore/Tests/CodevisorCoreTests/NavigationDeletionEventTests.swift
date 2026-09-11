import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NavigationDeletionEventTests {
  @Test(
    "Workspace and project deletions cannot be resurrected by an older snapshot",
    arguments: ["workspace.deleted", "project.deleted"], [false, true])
  func deletionSupersedesWorkspaceSnapshot(kind: String, notHydrated: Bool) async throws {
    let fixture = WorkspaceEventFixture()
    let emptyWorkspace = Workspace(
      name: "Empty", rootDirectory: nil, serverId: fixture.serverId, projectId: fixture.workspace.projectId,
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      createdAt: fixture.workspace.createdAt, isServerSynced: true
    )
    let unrelated = Workspace(
      name: "Unrelated project", rootDirectory: nil, serverId: fixture.serverId, projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      createdAt: fixture.workspace.createdAt, isServerSynced: true
    )
    fixture.repository.save(emptyWorkspace)
    fixture.repository.save(unrelated)
    if notHydrated { fixture.repository.delete(id: fixture.workspace.id) }
    let snapshot = ServerWorkspaceSnapshot(
      workspaces: [fixture.workspace, emptyWorkspace, unrelated].map(WorkspaceSyncModel.serverWorkspace), panes: []
    )
    let started = TestSignal()
    let release = TestSignal()
    fixture.fake.workspaceSnapshotHandler = {
      started.signal()
      await release.wait()
      return snapshot
    }
    let refresh = Task {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    defer {
      release.signal()
      refresh.cancel()
      fixture.controller.stopEventSync()
    }
    await started.wait()
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    let subjectId = kind == "project.deleted" ? fixture.workspace.projectId : fixture.workspace.id
    fixture.fake.emit(kind: kind, subjectId: subjectId.uuidString)
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()
    release.signal()
    #expect(await refresh.value == .superseded)

    #expect(fixture.repository.workspace(id: fixture.workspace.id) == nil)
    if kind == "project.deleted" {
      #expect(fixture.repository.workspace(id: emptyWorkspace.id) == nil)
      // The project itself wasn't cached; its cached children must still go.
      #expect(fixture.sync.projectList.sessions.isEmpty)
    } else {
      #expect(fixture.repository.workspace(id: emptyWorkspace.id) == emptyWorkspace)
    }
    #expect(fixture.repository.workspace(id: unrelated.id) == unrelated)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == fixture.otherWorkspace)
  }

  @Test(
    "Session deletion removes orphan panes and invalid routes without a server workspace assignment",
    arguments: [PaneKind.chat, .browser, .terminal])
  func sessionDeletionPrunesPanesBeforeRefresh(selectedKind: PaneKind) async throws {
    let clock = TestClock()
    let fixture = WorkspaceEventFixture(navigationSleep: clock.sleep)
    if selectedKind != .chat {
      var workspace = fixture.workspace
      let pane = PaneDescriptorState(id: UUID(), kind: selectedKind, name: "Page", terminalKey: "page")
      let tab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [pane], selectedPaneId: pane.id)))
      workspace.centerTabs.append(tab)
      workspace.selectedCenterTabId = tab.id
      fixture.repository.save(workspace)
    }
    defer { fixture.controller.stopEventSync() }
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    #expect(fixture.sync.projectList.workspaceAssignments(for: fixture.serverId).isEmpty)

    fixture.fake.emit(kind: "session.deleted", subjectId: fixture.anchorSessionId.uuidString)
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()

    let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(updated.pane(containingChat: fixture.anchorSessionId) == nil)
    #expect(!updated.centerTabs.isEmpty)
    #expect(fixture.sync.projectList.sessions.isEmpty)
    #expect(fixture.routeDisposition == .dismiss)
    #expect(fixture.fake.workspaceSnapshotCallCount == 1)
    await clock.waitForSleep(.seconds(2))
    let retry = try #require(fixture.controller.connection(for: fixture.serverId).navigationRetryTask)
    fixture.controller.stopEventSync()
    await retry.value
    #expect(clock.pendingCount == 0)
  }

  @Test(
    "Live session state and deletions supersede older project/session snapshots",
    arguments: ["session.archived", "session.deleted", "project.deleted"])
  func liveEventSupersedesProjectSnapshot(kind: String) async throws {
    let fixture = WorkspaceEventFixture()
    let model = fixture.sync.projectList
    let project = ServerProject(
      id: fixture.workspace.projectId.uuidString, name: "Shared", isArchived: false, origin: .codevisor,
      createdAt: "2026-06-30T00:00:00.000Z", locations: []
    )
    let session = ServerSession(
      id: fixture.anchorSessionId.uuidString, projectId: project.id, serverId: "local",
      harnessId: "codex", title: "Chat", origin: .codevisor, isArchived: false,
      workspaceId: fixture.workspace.id.uuidString, createdAt: "2026-06-30T00:00:00.000Z"
    )
    let client = FakeServerClient(projects: [project], sessions: [session])
    let started = TestSignal()
    let release = TestSignal()
    await client.setListDelay {
      started.signal()
      await release.wait()
    }
    let refresh = Task { await model.refreshFromServer(serverId: fixture.serverId, client: client) }
    defer {
      release.signal()
      refresh.cancel()
    }
    await started.wait()

    switch kind {
    case "session.deleted": model.removeSessionLocally(id: fixture.anchorSessionId, serverId: fixture.serverId)
    case "project.deleted": model.removeProjectLocally(id: fixture.workspace.projectId, serverId: fixture.serverId)
    default:
      let event = ServerEventEnvelope(
        id: 1, serverId: "local", kind: kind, subjectId: session.id, createdAt: session.createdAt,
        payload: .object([
          "id": .string(session.id), "projectId": .string(project.id), "serverId": .string("local"),
          "harnessId": .string("codex"), "title": .string("Archived remotely"),
          "origin": .string("codevisor"), "isArchived": .bool(true), "createdAt": .string(session.createdAt),
        ])
      )
      _ = await model.applyServerSessionEvent(event, serverId: fixture.serverId)
    }
    release.signal()
    #expect(await refresh.value == .superseded)
    if kind == "session.archived" {
      #expect(model.sessions.first?.isArchived == true)
      #expect(model.sessions.first?.title == "Archived remotely")
    } else {
      #expect(model.sessions.isEmpty)
    }
  }
}
