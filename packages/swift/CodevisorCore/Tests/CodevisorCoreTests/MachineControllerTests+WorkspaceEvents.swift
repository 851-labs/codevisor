import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
extension MachineControllerTests {
  @Test("Remote workspace archive and restore events apply even when snapshots fail")
  func workspaceMetadataEventsSurviveSnapshotFailure() async throws {
    let fixture = WorkspaceEventFixture()
    fixture.fake.workspaceSnapshotHandler = { throw URLError(.networkConnectionLost) }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    defer { fixture.controller.stopEventSync() }
    #expect(fixture.routeDisposition == .keep)

    for (index, archived) in [true, false].enumerated() {
      fixture.fake.emit(
        kind: "workspace.updated", subjectId: fixture.workspace.id.uuidString.lowercased(),
        payload: fixture.payload(isArchived: archived, name: "Renamed on Mac")
      )
      // The next event's callback acknowledges completion of the workspace event,
      // including a failed snapshot request in the regression case.
      fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
      await handled.wait(for: index + 1)

      let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id))
      #expect(updated.isArchived == archived)
      #expect(updated.name == "Renamed on Mac")
      #expect(updated.centerTabs == fixture.workspace.centerTabs)
      #expect(updated.serverId == fixture.serverId)
      #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == fixture.otherWorkspace)
      #expect(fixture.sync.revision == UInt64(index + 1))
      #expect(fixture.routeDisposition == (archived ? .dismiss : .keep))
    }
    #expect(fixture.fake.workspaceSnapshotCallCount == 0)
  }

  @Test("Workspace events supersede older snapshots, including unchanged metadata", arguments: [true, false])
  func workspaceEventSupersedesSnapshot(isArchived: Bool) async throws {
    let fixture = WorkspaceEventFixture()
    let started = TestSignal()
    let release = TestSignal()
    var staleRecord = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    staleRecord.isArchived = !isArchived
    let staleSnapshot = ServerWorkspaceSnapshot(workspaces: [staleRecord], panes: [])
    fixture.fake.workspaceSnapshotHandler = {
      started.signal()
      await release.wait()
      return staleSnapshot
    }
    let refresh = Task {
      await fixture.sync.refreshFromServer(serverId: fixture.serverId, client: fixture.fake)
    }
    defer {
      release.signal()
      refresh.cancel()
    }
    await started.wait()

    let event = fixture.event(isArchived: isArchived)
    #expect(fixture.sync.applyServerWorkspaceEvent(event, serverId: fixture.serverId))
    release.signal()
    #expect(await refresh.value == .superseded)

    let updated = try #require(fixture.repository.workspace(id: fixture.workspace.id))
    #expect(updated.isArchived == isArchived)
    #expect(updated.centerTabs == fixture.workspace.centerTabs)
    #expect(fixture.sync.revision == (isArchived ? 1 : 0))
  }

  @Test("Unknown workspaces and legacy marker events still hydrate from snapshots", arguments: [true, false])
  func workspaceEventSnapshotFallback(unknownWorkspace: Bool) async throws {
    let fixture = WorkspaceEventFixture()
    if unknownWorkspace { fixture.repository.delete(id: fixture.workspace.id) }
    var record = WorkspaceSyncModel.serverWorkspace(from: fixture.workspace)
    record.isArchived = true
    let snapshot = ServerWorkspaceSnapshot(workspaces: [record], panes: [])
    fixture.fake.workspaceSnapshotHandler = { snapshot }
    let handled = TestSignal()
    fixture.controller.onPluginUpdated = { _, _ in handled.signal() }
    fixture.controller.startEventSync(serverId: fixture.serverId, client: fixture.fake, since: 0)
    defer { fixture.controller.stopEventSync() }

    fixture.fake.emit(
      kind: "workspace.updated", subjectId: fixture.workspace.id.uuidString,
      payload: unknownWorkspace ? fixture.payload(isArchived: true, name: "Shared") : .null
    )
    fixture.fake.emit(kind: "plugin.updated", subjectId: "event-barrier")
    await handled.wait()

    #expect(fixture.repository.workspace(id: fixture.workspace.id)?.isArchived == true)
    #expect(fixture.fake.workspaceSnapshotCallCount == 1)
    #expect(fixture.repository.workspace(id: fixture.otherWorkspace.id) == fixture.otherWorkspace)
  }

  @Test(
    "Workspace metadata events require matching identity and an adopted workspace",
    arguments: ["subject", "project", "machine", "unadopted", "malformed"])
  func workspaceEventValidatesIdentity(mismatch: String) {
    let fixture = WorkspaceEventFixture()
    var event = fixture.event(isArchived: true)
    var serverId = fixture.serverId
    var expected = fixture.workspace
    switch mismatch {
    case "subject": event.subjectId = UUID().uuidString
    case "project":
      if case var .object(payload) = event.payload {
        payload["projectId"] = .string(UUID().uuidString)
        event.payload = .object(payload)
      }
    case "machine": serverId = "another-mac"
    case "unadopted":
      expected.isServerSynced = false
      fixture.repository.save(expected)
    default: event.payload = .object(["isArchived": .bool(true)])
    }

    #expect(!fixture.sync.applyServerWorkspaceEvent(event, serverId: serverId))
    #expect(fixture.repository.workspace(id: expected.id) == expected)
    #expect(fixture.sync.revision == 0)
  }
}

@MainActor
struct WorkspaceEventFixture {
  let serverId = "remote-mac"
  let anchorSessionId = UUID()
  let repository = DefaultWorkspaceRepository(store: InMemoryStore())
  let fake = SyncFakeServerClient(projects: [], sessions: [])
  let workspace: Workspace
  let otherWorkspace: Workspace
  let sync: WorkspaceSyncModel
  let controller: MachineController

  init(navigationClock: any Clock<Duration> = ContinuousClock()) {
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    workspace = Workspace(
      name: "Shared", rootDirectory: "/tmp/shared", serverId: serverId, projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: anchorSessionId)))],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), isServerSynced: true
    )
    otherWorkspace = Workspace(
      name: "Other machine", rootDirectory: nil, serverId: "another-mac", projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(PaneGroupState()))],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), isServerSynced: true
    )
    repository.save(workspace)
    repository.save(otherWorkspace)
    projectList.sessions = [
      ChatSession(
        id: anchorSessionId, projectId: workspace.projectId, serverId: serverId,
        createdAt: workspace.createdAt
      )
    ]
    sync = WorkspaceSyncModel(repository: repository, projectList: projectList)
    let client = fake
    controller = MachineController(
      store: InMemoryStore(), projectList: projectList, workspaceSync: sync,
      clientFactory: { _ in client }, navigationClock: navigationClock
    )
  }

  var routeDisposition: WorkspaceRouteDisposition {
    sync.routeDisposition(
      workspaceId: workspace.id, anchorSessionId: anchorSessionId, serverId: serverId,
      preservingSelectedPane: true
    )
  }

  func payload(isArchived: Bool, name: String) -> JSONValue {
    .object([
      "id": .string(workspace.id.uuidString),
      // The server's own identity differs from the client's route key.
      "serverId": .string("local"),
      "projectId": .string(workspace.projectId.uuidString),
      "name": .string(name),
      "hasCustomName": .bool(name != workspace.name),
      "isArchived": .bool(isArchived),
      "createdAt": .string("2026-06-30T00:00:00.000Z"),
    ])
  }

  func event(isArchived: Bool) -> ServerEventEnvelope {
    ServerEventEnvelope(
      id: 1, serverId: "local", kind: "workspace.updated",
      subjectId: workspace.id.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
      payload: payload(isArchived: isArchived, name: workspace.name)
    )
  }
}
