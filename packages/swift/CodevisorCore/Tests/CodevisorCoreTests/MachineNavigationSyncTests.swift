import Foundation
import Observation
import Testing
import CodevisorTestSupport
import ACPKit

@testable import CodevisorCore

@MainActor
struct MachineNavigationSyncTests {
  @Test("Navigation refresh serializes snapshot and event replay")
  func snapshotAndReplayAreSerialized() async throws {
    let projectId = UUID()
    let sessionId = UUID()
    let project = ServerProject(
      id: projectId.uuidString,
      name: "Shared",
      origin: .codevisor,
      createdAt: "2026-08-21T20:00:00.000Z",
      locations: [
        ServerProjectLocation(
          id: UUID().uuidString,
          projectId: projectId.uuidString,
          serverId: "local",
          folderPath: "/tmp/shared",
          createdAt: "2026-08-21T20:00:00.000Z",
          isGitRepository: true
        )
      ]
    )
    let active = ServerSession(
      id: sessionId.uuidString,
      projectId: projectId.uuidString,
      serverId: "local",
      harnessId: "codex",
      title: "Initially active",
      origin: .codevisor,
      createdAt: "2026-08-21T20:00:01.000Z"
    )
    let fake = NavigationSyncFakeServerClient(projects: [project], sessions: [active])
    let projectList = makeProjectList()
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: projectList,
      clientFactory: { _ in fake }
    )

    await controller.refreshNavigationState(for: "local")
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    #expect(projectList.sessions.first?.title == "Initially active")

    let snapshotGate = Latch()
    fake.configureListSessionDelay { await snapshotGate.wait() }
    var snapshotUpdate = active
    snapshotUpdate.title = "Renamed by snapshot"
    fake.setSessions([snapshotUpdate])

    let callCountBeforeRefresh = fake.listSessionCallCount
    let firstRefresh = Task {
      await controller.synchronizeNavigationState(
        serverId: "local",
        client: fake,
        presentation: .catchUp
      )
    }
    try await waitUntil {
      fake.listSessionCallCount == callCountBeforeRefresh + 1
    }
    // A machine that already presented a current snapshot keeps it during
    // a warm catch-up: the cursor makes the resync gapless, and demoting
    // to `.catchingUp` would evict its rows from fleet-aggregated lists.
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)

    // This event lands after the cursor was captured but while the list
    // request is blocked. It must replay after the snapshot commits.
    var replayed = snapshotUpdate
    replayed.title = "Updated during snapshot"
    replayed.updatedAt = "2026-08-21T21:00:01.000Z"
    fake.emit(
      kind: "session.updated",
      subjectId: sessionId.uuidString,
      payload: navigationSessionPayload(replayed)
    )

    let joining = TestSignal()
    let joinedRefresh = Task { @MainActor in
      joining.signal()
      await controller.refreshNavigationState(for: "local")
    }
    await joining.wait()
    #expect(fake.listSessionCallCount == callCountBeforeRefresh + 1)

    await snapshotGate.open()
    await firstRefresh.value
    await joinedRefresh.value
    try await waitUntil {
      projectList.sessions.first(where: { $0.id == sessionId })?.title
        == "Updated during snapshot"
    }

    // The replayed event lands after the snapshot commits, so its title is
    // the one that survives — the ordering this test exists to pin.
    let reconciled = try #require(projectList.sessions.first { $0.id == sessionId })
    #expect(reconciled.title == "Updated during snapshot")
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    #expect(fake.listSessionCallCount == callCountBeforeRefresh + 1)
  }

  @Test("Background navigation refresh keeps the current projection visible")
  func backgroundRefreshStaysCurrent() async throws {
    let fake = NavigationSyncFakeServerClient(projects: [], sessions: [])
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: makeProjectList(),
      clientFactory: { _ in fake }
    )

    await controller.refreshNavigationState(for: "local")
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)

    let snapshotGate = Latch()
    fake.configureListSessionDelay { await snapshotGate.wait() }
    let callCountBeforeRefresh = fake.listSessionCallCount
    let refresh = Task { await controller.refreshNavigationState(for: "local") }
    try await waitUntil {
      fake.listSessionCallCount == callCountBeforeRefresh + 1
    }

    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    await snapshotGate.open()
    await refresh.value
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
  }

  @Test("Live navigation events reconcile without entering catch-up")
  func liveEventsReconcileInBackground() async throws {
    let fake = NavigationSyncFakeServerClient(projects: [], sessions: [])
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: makeProjectList(),
      clientFactory: { _ in fake }
    )

    await controller.refreshNavigationState(for: "local")

    defer { controller.stopEventSync() }
    let applied = TestSignal()
    controller.onPluginUpdated = { _, _ in applied.signal() }
    let before = fake.listSessionCallCount
    fake.emit(
      kind: "navigation.changed", subjectId: "navigation",
      payload: .object([
        "eventCursor": .number(1), "projects": .array([]), "sessions": .array([]),
        "workspaces": .array([]), "panes": .array([]), "deleted": .array([]),
      ]))
    fake.emit(kind: "plugin.updated", subjectId: "barrier", payload: .object([:]))
    await applied.wait()
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
    #expect(fake.listSessionCallCount == before)
  }

  @Test("A settled sign-in probe invalidates the harness catalog without a lifecycle re-read")
  func authEventInvalidatesCatalog() async throws {
    // Onboarding fetches the catalog passively; the server resolves the
    // account in the background and announces it with `harness.auth.updated`.
    // Without this hop the row stays on "Checking sign-in…" indefinitely.
    let fake = NavigationSyncFakeServerClient(projects: [], sessions: [])
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: makeProjectList(),
      clientFactory: { _ in fake }
    )
    await controller.refreshNavigationState(for: "local")
    defer { controller.stopEventSync() }

    let barrier = TestSignal()
    let authChanged = TestSignal()
    let lifecycleChanged = TestSignal()
    controller.onHarnessAuthChanged = { serverId in
      #expect(serverId == "local")
      authChanged.signal()
    }
    controller.onHarnessLifecycleChanged = { _ in lifecycleChanged.signal() }
    controller.onPluginUpdated = { _, _ in barrier.signal() }
    fake.emit(
      kind: "harness.auth.updated", subjectId: "claude-code",
      payload: .object(["id": .string("shared-1"), "authState": .string("authenticated")]))
    fake.emit(kind: "plugin.updated", subjectId: "barrier", payload: .object([:]))
    await barrier.wait()
    #expect(authChanged.value == 1)
    #expect(lifecycleChanged.value == 0)
  }

  @Test("A cold catch-up still presents the blocking catch-up state")
  func coldCatchUpBlocks() async throws {
    let fake = NavigationSyncFakeServerClient(projects: [], sessions: [])
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: makeProjectList(),
      clientFactory: { _ in fake }
    )

    // Nothing current yet: the machine has never synced this launch.
    let snapshotGate = Latch()
    fake.configureListSessionDelay { await snapshotGate.wait() }
    let refresh = Task {
      await controller.synchronizeNavigationState(
        serverId: "local",
        client: fake,
        presentation: .catchUp
      )
    }
    try await waitUntil { fake.listSessionCallCount == 1 }
    #expect(controller.navigationSyncStateByMachineId["local"] == .catchingUp)

    await snapshotGate.open()
    await refresh.value
    #expect(controller.navigationSyncStateByMachineId["local"] == .current)
  }

  @Test(
    "Failed navigation sync stays visible through retries until a snapshot succeeds",
    arguments: [NavigationSyncPresentation.background, .catchUp]
  )
  func failureIsVisibleAndRetryable(presentation: NavigationSyncPresentation) async throws {
    let fake = NavigationSyncFakeServerClient(projects: [], sessions: [])
    fake.configureListSessionsFailure(true)
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: makeProjectList(),
      clientFactory: { _ in fake }
    )
    defer { controller.stopEventSync() }

    await controller.refreshNavigationState(for: "local")
    let failure = try #require(controller.navigationSyncStateByMachineId["local"])
    guard case .stale = failure else {
      Issue.record("A failed snapshot was incorrectly presented as current")
      return
    }

    for retryFails in [true, false] {
      let snapshotStarted = TestSignal()
      let snapshotGate = TestSignal()
      fake.configureListSessionDelay {
        snapshotStarted.signal()
        await snapshotGate.wait()
      }
      fake.configureListSessionsFailure(retryFails)
      let retry = Task {
        await controller.synchronizeNavigationState(
          serverId: "local", client: fake, presentation: presentation
        )
      }
      await snapshotStarted.wait()
      #expect(controller.navigationSyncStateByMachineId["local"] == failure)

      // A catch-up joining an in-flight retry must also retain the error.
      let joining = TestSignal()
      let joinedRetry = Task { @MainActor in
        joining.signal()
        await controller.synchronizeNavigationState(
          serverId: "local", client: fake, presentation: .catchUp
        )
      }
      await joining.wait()
      #expect(controller.navigationSyncStateByMachineId["local"] == failure)

      snapshotGate.signal()
      await retry.value
      await joinedRetry.value
      #expect(controller.navigationSyncStateByMachineId["local"] == (retryFails ? failure : .current))
    }
  }

  private func makeProjectList() -> ProjectListModel {
    ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
  }
}

private func navigationSessionPayload(_ session: ServerSession) -> JSONValue {
  var payload: [String: JSONValue] = [
    "id": .string(session.id),
    "projectId": .string(session.projectId),
    "serverId": .string(session.serverId),
    "harnessId": .string(session.harnessId),
    "title": .string(session.title),
    "origin": .string(session.origin.rawValue),
    "createdAt": .string(session.createdAt),
  ]
  if let updatedAt = session.updatedAt {
    payload["updatedAt"] = .string(updatedAt)
  }
  return .object(payload)
}

@Observable
private final class NavigationSyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private struct ListSessionsFailure: Error {}

  private let lock = NSLock()
  private var projects: [ServerProject]
  private var sessions: [ServerSession]
  private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
  private var events: [ServerEventEnvelope] = []
  private var nextEventId = 1
  private var sessionListCalls = 0
  private var sessionListDelay: (@Sendable () async -> Void)?
  private var failsSessionList = false

  init(projects: [ServerProject], sessions: [ServerSession]) {
    self.projects = projects
    self.sessions = sessions
  }

  var listSessionCallCount: Int { lock.withLock { sessionListCalls } }

  func setSessions(_ sessions: [ServerSession]) {
    lock.withLock { self.sessions = sessions }
  }

  func configureListSessionDelay(_ delay: (@Sendable () async -> Void)?) {
    lock.withLock { sessionListDelay = delay }
  }

  func configureListSessionsFailure(_ fails: Bool) {
    lock.withLock { failsSessionList = fails }
  }

  func emit(kind: String, subjectId: String, payload: JSONValue) {
    let (event, targets): (ServerEventEnvelope, [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation]) =
      lock.withLock {
        let event = ServerEventEnvelope(
          id: nextEventId,
          serverId: "local",
          kind: kind.hasPrefix("session.") ? "navigation.changed" : kind,
          subjectId: subjectId,
          createdAt: "2026-08-21T21:00:01.000Z",
          payload: kind.hasPrefix("session.")
            ? .object([
              "eventCursor": .number(Double(nextEventId)), "projects": .array([]), "sessions": .array([payload]),
              "workspaces": .array([]), "panes": .array([]), "deleted": .array([]),
            ]) : payload
        )
        nextEventId += 1
        events.append(event)
        return (event, continuations)
      }
    for continuation in targets {
      continuation.yield(event)
    }
  }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      let backlog = lock.withLock {
        continuations.append(continuation)
        return events.filter { $0.id > since }
      }
      for event in backlog {
        continuation.yield(event)
      }
    }
  }

  func listProjects() async throws -> [ServerProject] {
    lock.withLock { projects }
  }

  func listSessions() async throws -> [ServerSession] {
    let (snapshot, delay, fails) = lock.withLock {
      sessionListCalls += 1
      return (sessions, sessionListDelay, failsSessionList)
    }
    if let delay { await delay() }
    if fails { throw ListSessionsFailure() }
    return snapshot
  }

  func latestShellEventCursor() async throws -> Int {
    lock.withLock { nextEventId - 1 }
  }

  func health() async throws -> ServerHealth { fatalError("unused") }
  func info() async throws -> ServerInfo { fatalError("unused") }
  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    fatalError("unused")
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities {
    ServerCapabilities(harnesses: [])
  }
  func listHarnesses() async throws -> [ServerHarness] { fatalError("unused") }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
    fatalError("unused")
  }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    fatalError("unused")
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
