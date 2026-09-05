import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

@MainActor
extension MachineControllerTests {
  @Test("Server events keep projects and sessions in sync across clients")
  func eventSyncRefreshesAndRemoves() async throws {
    let projectId = UUID()
    let sessionId = UUID()
    let fake = SyncFakeServerClient(
      projects: [
        ServerProject(
          id: projectId.uuidString,
          name: "Shared",
          isArchived: false,
          origin: .codevisor,
          createdAt: "2026-06-30T00:00:00.000Z",
          locations: [
            ServerProjectLocation(
              id: UUID().uuidString,
              projectId: projectId.uuidString,
              serverId: "local",
              folderPath: "/tmp/shared",
              createdAt: "2026-06-30T00:00:00.000Z",
              isGitRepository: nil
            )
          ]
        )
      ],
      sessions: []
    )
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake }
    )

    // Another client creates a session on the same server.
    controller.startEventSync(for: "local")
    fake.setSessions([
      ServerSession(
        id: sessionId.uuidString,
        projectId: projectId.uuidString,
        serverId: "local",
        harnessId: "claude-code",
        agentSessionId: nil,
        title: "From another client",
        origin: .codevisor,
        isArchived: false,
        createdAt: "2026-06-30T00:00:01.000Z",
        updatedAt: nil,
        usage: nil
      )
    ])
    fake.emit(kind: "session.created", subjectId: sessionId.uuidString)
    try await waitForSync { projectList.sessions.contains { $0.id == sessionId } }
    #expect(projectList.projects.contains { $0.id == projectId })

    // Ordinary session events carry their authoritative summary. Applying
    // one must update only that cached row instead of listing and mapping
    // every session again.
    let fullRefreshCount = fake.listSessionCallCount
    let updated = ServerSession(
      id: sessionId.uuidString,
      projectId: projectId.uuidString,
      serverId: "local",
      harnessId: "claude-code",
      agentSessionId: nil,
      title: "Updated incrementally",
      origin: .codevisor,
      isArchived: false,
      createdAt: "2026-06-30T00:00:01.000Z",
      updatedAt: "2026-06-30T00:00:02.000Z",
      usage: nil
    )
    fake.emit(
      kind: "session.updated",
      subjectId: sessionId.uuidString,
      payload: sessionPayload(updated)
    )
    try await waitForSync {
      projectList.sessions.first(where: { $0.id == sessionId })?.title
        == "Updated incrementally"
    }
    #expect(fake.listSessionCallCount == fullRefreshCount)

    // Another client deletes the session, then the project.
    fake.setSessions([])
    fake.emit(kind: "session.deleted", subjectId: sessionId.uuidString)
    try await waitForSync { !projectList.sessions.contains { $0.id == sessionId } }

    fake.setProjects([])
    fake.emit(kind: "project.deleted", subjectId: projectId.uuidString)
    try await waitForSync { !projectList.projects.contains { $0.id == projectId } }

    controller.stopEventSync()
  }

  @Test("Plugin events bridge list invalidation and per-plugin reloads")
  func pluginEventBridging() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake }
    )
    var stateChanges: [String] = []
    var updates: [[String]] = []
    controller.onPluginStateChanged = { stateChanges.append($0) }
    let pluginUpdated = TestSignal()
    controller.onPluginUpdated = {
      updates.append([$0, $1]); pluginUpdated.signal()
    }

    controller.startEventSync(for: "local")
    // Runtime transitions invalidate the machine's plugin list…
    fake.emit(kind: "plugin.state.updated", subjectId: "owner.example")
    // …while only plugin.updated (code/install changed) triggers pane
    // reloads, carrying the plugin id so unrelated panes stay put.
    fake.emit(kind: "plugin.updated", subjectId: "owner.example")
    await pluginUpdated.wait()
    #expect(updates == [["local", "owner.example"]])
    #expect(stateChanges == ["local"])

    controller.stopEventSync()
  }

  @Test("Workspace and unarchive events drive shared navigation state")
  func workspaceEventSync() async throws {
    let projectId = UUID()
    let sessionId = UUID()
    let siblingSessionId = UUID()
    let workspaceId = UUID()
    let project = ServerProject(
      id: projectId.uuidString,
      name: "Shared",
      isArchived: false,
      origin: .codevisor,
      createdAt: "2026-06-30T00:00:00.000Z",
      locations: [
        ServerProjectLocation(
          id: UUID().uuidString,
          projectId: projectId.uuidString,
          serverId: "local",
          folderPath: "/tmp/shared",
          createdAt: "2026-06-30T00:00:00.000Z",
          isGitRepository: nil
        )
      ]
    )
    func serverSession(id: UUID, isArchived: Bool, workspaceId: UUID?) -> ServerSession {
      ServerSession(
        id: id.uuidString,
        projectId: projectId.uuidString,
        serverId: "local",
        harnessId: "codex",
        agentSessionId: nil,
        title: "Shared chat",
        origin: .codevisor,
        isArchived: isArchived,
        worktreeName: nil,
        workspaceId: workspaceId?.uuidString,
        cwd: "/tmp/shared",
        createdAt: "2026-06-30T00:00:01.000Z",
        updatedAt: nil,
        usage: nil
      )
    }
    func serverWorkspace(isArchived: Bool) -> ServerWorkspace {
      ServerWorkspace(
        id: workspaceId.uuidString,
        serverId: "local",
        projectId: projectId.uuidString,
        name: "Shared workspace",
        hasCustomName: true,
        rootDirectory: "/tmp/shared",
        isArchived: isArchived,
        archivedAt: isArchived ? "2026-06-30T00:00:02.000Z" : nil,
        createdAt: "2026-06-30T00:00:00.000Z",
        updatedAt: nil
      )
    }

    let fake = SyncFakeServerClient(
      projects: [project],
      sessions: [
        serverSession(id: sessionId, isArchived: false, workspaceId: workspaceId),
        serverSession(id: siblingSessionId, isArchived: false, workspaceId: workspaceId),
      ],
      workspaces: [serverWorkspace(isArchived: false)]
    )
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let workspaceRepository = DefaultWorkspaceRepository(store: InMemoryStore())
    let workspaceSync = WorkspaceSyncModel(
      repository: workspaceRepository,
      projectList: projectList
    )
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      workspaceSync: workspaceSync,
      clientFactory: { _ in fake }
    )

    // Production establishes one authoritative snapshot before opening
    // the live-only event stream.
    await controller.refreshNavigationState(for: "local")
    controller.startEventSync(for: "local")
    fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
    try await waitForSync {
      _ = workspaceSync.revision
      return workspaceRepository.workspace(id: workspaceId)?.isServerSynced == true
    }
    #expect(workspaceRepository.workspace(id: workspaceId)?.name == "Shared workspace")
    #expect(
      workspaceSync.routeDisposition(
        workspaceId: workspaceId,
        anchorSessionId: sessionId,
        serverId: "local"
      ) == .keep
    )

    // Archiving one chat selects a surviving sibling on both platforms.
    let archivedSession = serverSession(
      id: sessionId,
      isArchived: true,
      workspaceId: workspaceId
    )
    let activeSibling = serverSession(
      id: siblingSessionId,
      isArchived: false,
      workspaceId: workspaceId
    )
    fake.setSessions([archivedSession, activeSibling])
    fake.emit(
      kind: "session.archived",
      subjectId: sessionId.uuidString,
      payload: sessionPayload(archivedSession)
    )
    try await waitForSync {
      projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == true
    }
    #expect(
      workspaceSync.routeDisposition(
        workspaceId: workspaceId,
        anchorSessionId: sessionId,
        serverId: "local"
      ) == .selectSession(siblingSessionId)
    )
    #expect(
      workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local")
        == .selectSession(siblingSessionId)
    )

    // The previously missing unarchive event restores the original route.
    let unarchivedSession = serverSession(
      id: sessionId,
      isArchived: false,
      workspaceId: workspaceId
    )
    fake.setSessions([unarchivedSession, activeSibling])
    fake.emit(
      kind: "session.unarchived",
      subjectId: sessionId.uuidString,
      payload: sessionPayload(unarchivedSession)
    )
    try await waitForSync {
      projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == false
    }
    #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .keep)

    let archivedSibling = serverSession(
      id: siblingSessionId,
      isArchived: true,
      workspaceId: workspaceId
    )
    fake.setSessions([archivedSession, archivedSibling])
    fake.setWorkspaces([serverWorkspace(isArchived: true)])
    fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
    fake.emit(
      kind: "session.archived",
      subjectId: sessionId.uuidString,
      payload: sessionPayload(archivedSession)
    )
    fake.emit(
      kind: "session.archived",
      subjectId: siblingSessionId.uuidString,
      payload: sessionPayload(archivedSibling)
    )
    try await waitForSync {
      _ = workspaceSync.revision
      return workspaceRepository.workspace(id: workspaceId)?.isArchived == true
        && projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == true
    }
    #expect(
      workspaceSync.routeDisposition(
        workspaceId: workspaceId,
        anchorSessionId: sessionId,
        serverId: "local"
      ) == .dismiss
    )

    let unarchivedSibling = serverSession(
      id: siblingSessionId,
      isArchived: false,
      workspaceId: workspaceId
    )
    fake.setSessions([unarchivedSession, unarchivedSibling])
    fake.setWorkspaces([serverWorkspace(isArchived: false)])
    fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
    fake.emit(
      kind: "session.unarchived",
      subjectId: sessionId.uuidString,
      payload: sessionPayload(unarchivedSession)
    )
    fake.emit(
      kind: "session.unarchived",
      subjectId: siblingSessionId.uuidString,
      payload: sessionPayload(unarchivedSibling)
    )
    try await waitForSync {
      _ = workspaceSync.revision
      return workspaceRepository.workspace(id: workspaceId)?.isArchived == false
        && projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == false
    }
    #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .keep)

    fake.setSessions([
      serverSession(id: sessionId, isArchived: false, workspaceId: nil),
      serverSession(id: siblingSessionId, isArchived: false, workspaceId: nil),
    ])
    fake.setWorkspaces([])
    fake.emit(kind: "workspace.deleted", subjectId: workspaceId.uuidString)
    try await waitForSync {
      _ = workspaceSync.revision
      return workspaceRepository.workspace(id: workspaceId) == nil
    }
    #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .dismiss)

    controller.stopEventSync()
  }
}

private func sessionPayload(_ session: ServerSession) -> JSONValue {
  var payload: [String: JSONValue] = [
    "id": .string(session.id),
    "projectId": .string(session.projectId),
    "serverId": .string(session.serverId),
    "harnessId": .string(session.harnessId),
    "title": .string(session.title),
    "origin": .string(session.origin.rawValue),
    "isArchived": .bool(session.isArchived),
    "createdAt": .string(session.createdAt),
  ]
  if let agentSessionId = session.agentSessionId {
    payload["agentSessionId"] = .string(agentSessionId)
  }
  if let workspaceId = session.workspaceId {
    payload["workspaceId"] = .string(workspaceId)
  }
  if let worktreeName = session.worktreeName {
    payload["worktreeName"] = .string(worktreeName)
  }
  if let cwd = session.cwd {
    payload["cwd"] = .string(cwd)
  }
  if let updatedAt = session.updatedAt {
    payload["updatedAt"] = .string(updatedAt)
  }
  if let sidebarState = session.sidebarState {
    payload["sidebarState"] = .string(sidebarState.rawValue)
  }
  if let sidebarStateChangedAt = session.sidebarStateChangedAt {
    payload["sidebarStateChangedAt"] = .string(sidebarStateChangedAt)
  }
  return .object(payload)
}
