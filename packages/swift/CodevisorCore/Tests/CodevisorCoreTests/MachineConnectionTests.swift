import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("MachineConnection streams")
struct MachineConnectionTests {
  private func makeRemote(_ id: String) -> CodevisorMachine {
    accountMachine(id)
  }

  private func makeController(
    fakes: [String: SyncFakeServerClient],
    remotes: [CodevisorMachine]
  ) throws -> (controller: MachineController, projectList: ProjectListModel) {
    let projectList = ProjectListModel.fixture()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { machine in fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: []) }
    )
    signIn(controller, machines: remotes)
    return (controller, projectList)
  }

  private func makeSession(id: UUID, projectId: UUID, serverId: String) -> ServerSession {
    ServerSession(
      id: id.uuidString,
      projectId: projectId.uuidString,
      serverId: serverId,
      harnessId: "claude-code",
      agentSessionId: nil,
      title: "Background work",
      origin: .codevisor,
      createdAt: "2026-06-30T00:00:01.000Z",
      updatedAt: "2026-06-30T00:00:02.000Z",
      usage: nil
    )
  }

  private func payload(for session: ServerSession) -> JSONValue {
    .object([
      "id": .string(session.id),
      "projectId": .string(session.projectId),
      "serverId": .string(session.serverId),
      "harnessId": .string(session.harnessId),
      "title": .string(session.title),
      "origin": .string(session.origin.rawValue),
      "createdAt": .string(session.createdAt),
      "updatedAt": .string(session.updatedAt ?? session.createdAt),
    ])
  }

  @Test("Connecting a background machine pulls its full snapshot")
  func connectSnapshotsBackgroundMachine() async throws {
    let remote = makeRemote("remote-a")
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/tmp/remote-work"),
      serverId: remote.id,
      origin: .codevisor
    )
    let session = makeSession(id: UUID(), projectId: project.id, serverId: remote.id)
    let fake = SyncFakeServerClient(
      projects: [serverProject(from: project)],
      sessions: [session]
    )
    let (controller, projectList) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }

    await controller.connectMachine(remote.id)

    #expect(
      projectList.sessions.contains {
        $0.serverId == remote.id && $0.id.uuidString == session.id
      })
    #expect(controller.navigationSyncStateByMachineId[remote.id] == .current)
  }

  @Test("An unreachable background machine lands a terminal stale state")
  func connectMarksUnreachableMachineStale() async throws {
    let remote = makeRemote("remote-down")
    let down = SyncFakeServerClient(projects: [], sessions: [])
    down.lock.withLock { down.downtimeRemaining = 100 }
    let (controller, _) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: down],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }

    await controller.connectMachine(remote.id)

    guard case .stale = controller.navigationSyncStateByMachineId[remote.id] else {
      Issue.record(
        "Expected .stale, got \(String(describing: controller.navigationSyncStateByMachineId[remote.id]))")
      return
    }
  }

  private func waitForSync(_ predicate: () -> Bool) async throws {
    await awaitObserved(predicate)
  }

  @Test("A background machine's live events apply while another machine is selected")
  func backgroundEventsApply() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    let (controller, projectList) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    #expect(controller.selectedMachineId == "local")

    await controller.connectMachine(remote.id)
    try await waitForSync { remoteFake.eventStreamSubscriberCount == 1 }

    let session = makeSession(id: UUID(), projectId: UUID(), serverId: remote.id)
    remoteFake.emit(
      kind: "session.created",
      subjectId: session.id,
      payload: payload(for: session)
    )
    try await waitForSync {
      projectList.sessions.contains {
        $0.serverId == remote.id && $0.id.uuidString == session.id.uppercased()
      }
    }
    #expect(controller.selectedMachineId == "local")
    #expect(projectList.sessions.allSatisfy { $0.serverId == remote.id })
  }

  @Test("connectMachine is idempotent while a stream is live")
  func connectIsIdempotent() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    let (controller, _) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }

    await controller.connectMachine(remote.id)
    await controller.connectMachine(remote.id)
    try await waitForSync { remoteFake.eventStreamSubscriberCount >= 1 }
    #expect(remoteFake.eventStreamSubscriberCount == 1)
  }

  @Test("update.changed events refresh a machine's release state live")
  func updateChangedEventApplies() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    let (controller, _) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    await controller.connectMachine(remote.id)
    try await waitForSync { remoteFake.eventStreamSubscriberCount == 1 }

    remoteFake.emit(
      kind: "update.changed",
      subjectId: "server",
      payload: .object([
        "currentVersion": .string("0.1.0"),
        "latestVersion": .string("9.9.9"),
        "updateAvailable": .bool(true),
        "channel": .string("stable"),
        "migrationState": .string("idle"),
      ])
    )
    try await waitForSync {
      controller.serverUpdateInfo(for: remote.id)?.latestVersion == "9.9.9"
    }
  }

  @Test("restart.drain.updated events pause sending on that machine until each paused chat resumes")
  func restartDrainEventsPauseSending() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    let (controller, _) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    await controller.connectMachine(remote.id)
    try await waitForSync { remoteFake.eventStreamSubscriberCount == 1 }
    let paused = UUID()
    let idle = UUID()
    #expect(!controller.isPausedForUpdate(machineId: remote.id, sessionId: idle))

    remoteFake.emit(
      kind: "restart.drain.updated",
      subjectId: "server",
      payload: .object([
        "state": .string("drained"), "remaining": .number(0),
        "startedAt": .string("2026-10-20T00:00:00.000Z"),
        "pausedSessionIds": .array([.string(paused.uuidString.lowercased())]),
      ])
    )
    try await waitForSync { controller.isPausedForUpdate(machineId: remote.id, sessionId: idle) }
    #expect(controller.isPausedForUpdate(machineId: remote.id, sessionId: nil))
    #expect(!controller.isPausedForUpdate(machineId: "local", sessionId: idle))

    remoteFake.emit(
      kind: "restart.drain.updated",
      subjectId: "server",
      payload: .object([
        "state": .string("idle"), "remaining": .number(0),
        "startedAt": .string("2026-10-20T00:01:00.000Z"),
        "pausedSessionIds": .array([.string(paused.uuidString.lowercased())]),
      ])
    )
    try await waitForSync { !controller.isPausedForUpdate(machineId: remote.id, sessionId: idle) }
    #expect(controller.isPausedForUpdate(machineId: remote.id, sessionId: paused))

    remoteFake.emit(
      kind: "restart.drain.updated",
      subjectId: "server",
      payload: .object([
        "state": .string("idle"), "remaining": .number(0),
        "startedAt": .string("2026-10-20T00:01:00.000Z"),
        "pausedSessionIds": .array([]),
      ])
    )
    try await waitForSync { !controller.isPausedForUpdate(machineId: remote.id, sessionId: paused) }
  }

  @Test("An update tracks on its own machine, not on the selected one")
  func updatePhaseIsPerMachine() async throws {
    let remote = makeRemote("remote-a")
    let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
    remoteFake.configureUpdate(current: "0.1.0", latest: "0.2.0")
    remoteFake.configureBusy(true)
    let (controller, _) = try makeController(
      fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
      remotes: [remote]
    )
    defer { controller.stopEventSync() }
    #expect(controller.selectedMachineId == "local")

    await controller.updateServer(machineId: remote.id)

    if case .failed = controller.connection(for: remote.id).updatePhase {
    } else {
      Issue.record("Expected the remote machine's phase to be failed")
    }
    #expect(controller.serverUpdatePhase(for: "local") == .idle)
  }

  @Test("refreshServerUpdates probes every reachable machine")
  func fleetUpdateRefresh() async throws {
    let remoteA = makeRemote("remote-a")
    let remoteB = makeRemote("remote-b")
    let fakeA = SyncFakeServerClient(projects: [], sessions: [])
    let fakeB = SyncFakeServerClient(projects: [], sessions: [])
    fakeA.configureUpdate(current: "0.1.0", latest: "0.2.0")
    fakeB.configureUpdate(current: "0.1.0", latest: "0.3.0")
    let (controller, _) = try makeController(
      fakes: [
        "local": SyncFakeServerClient(projects: [], sessions: []),
        remoteA.id: fakeA,
        remoteB.id: fakeB,
      ],
      remotes: [remoteA, remoteB]
    )
    defer { controller.stopEventSync() }

    await controller.connectMachine(remoteA.id)
    await controller.connectMachine(remoteB.id)
    await controller.refreshServerUpdates()

    #expect(controller.serverUpdateInfo(for: remoteA.id)?.latestVersion == "0.2.0")
    #expect(controller.serverUpdateInfo(for: remoteB.id)?.latestVersion == "0.3.0")
    #expect(fakeA.updateInfoRefreshes.last == false)
    #expect(fakeB.updateInfoRefreshes.last == false)
  }

  @Test("ensureBackgroundConnections opens a stream for every non-selected machine")
  func ensureConnectsRegisteredMachines() async throws {
    let remoteA = makeRemote("remote-a")
    let remoteB = makeRemote("remote-b")
    let fakeA = SyncFakeServerClient(projects: [], sessions: [])
    let fakeB = SyncFakeServerClient(projects: [], sessions: [])
    let (controller, _) = try makeController(
      fakes: [
        "local": SyncFakeServerClient(projects: [], sessions: []),
        remoteA.id: fakeA,
        remoteB.id: fakeB,
      ],
      remotes: [remoteA, remoteB]
    )
    defer { controller.stopEventSync() }

    controller.ensureBackgroundConnections()
    try await waitForSync {
      fakeA.eventStreamSubscriberCount == 1 && fakeB.eventStreamSubscriberCount == 1
    }
  }
}
