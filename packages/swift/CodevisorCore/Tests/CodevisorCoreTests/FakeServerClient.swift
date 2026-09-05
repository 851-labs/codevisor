import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

/// A reusable gate: `wait()` suspends callers until `open()` is called.
actor Latch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

@MainActor
func waitUntil(_ predicate: () -> Bool) async throws {
  await awaitObserved(predicate)
}

struct FakeServerSnapshot: Sendable {
  var upsertedProjectIDs: [String]
  var upsertedSessionIDs: [String]
  var deletedProjectIDs: [String]
  var deletedSessionIDs: [String]
  var readRequests: [FakeReadRequest]
}

struct FakeReadRequest: Equatable, Sendable {
  var sessionId: UUID
  var throughSequence: Int
}

actor FakeServerClient: CodevisorServerClienting {
  private let changed = TestSignal()

  func waitForSnapshot(_ predicate: @Sendable (FakeServerSnapshot) -> Bool) async {
    while true {
      let revision = changed.value
      if predicate(snapshot()) { return }
      await changed.wait(for: revision + 1)
    }
  }

  private var projects: [ServerProject]
  private var sessions: [ServerSession]
  private var upsertedProjectIDs: [String] = []
  private var upsertedSessionIDs: [String] = []
  private var deletedProjectIDs: [String] = []
  private var deletedSessionIDs: [String] = []
  private var readRequests: [FakeReadRequest] = []
  /// When set, `listProjects` suspends on this first — lets tests hold a
  /// "network" call in flight while the app state changes underneath it.
  private var listDelay: (@Sendable () async -> Void)?
  private var projectUpsertDelay: (@Sendable () async -> Void)?
  private var sessionUpsertDelay: (@Sendable () async -> Void)?
  /// When set, deleteProject/deleteSession suspend on this first — lets
  /// tests hold the server DELETE in flight while refreshes race it.
  private var deleteDelay: (@Sendable () async -> Void)?
  private var readResponseDelay: (@Sendable () async -> Void)?

  init(projects: [ServerProject] = [], sessions: [ServerSession] = []) {
    self.projects = projects
    self.sessions = sessions
  }

  func setListDelay(_ delay: @escaping @Sendable () async -> Void) {
    listDelay = delay
  }

  func setProjectUpsertDelay(_ delay: @escaping @Sendable () async -> Void) {
    projectUpsertDelay = delay
  }

  func setSessionUpsertDelay(_ delay: @escaping @Sendable () async -> Void) {
    sessionUpsertDelay = delay
  }

  func setDeleteDelay(_ delay: @escaping @Sendable () async -> Void) {
    deleteDelay = delay
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready")
  }

  func info() async throws -> ServerInfo { fatalError("unused") }

  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    fatalError("unused")
  }

  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }

  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }

  func listHarnesses() async throws -> [ServerHarness] { [] }

  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }

  func listProjects() async throws -> [ServerProject] {
    if let listDelay { await listDelay() }
    return projects
  }

  func upsertProject(_ project: Project) async throws -> ServerProject {
    if let projectUpsertDelay { await projectUpsertDelay() }
    let serverProject = serverProject(from: project)
    upsertedProjectIDs.append(serverProject.id)
    changed.signal()
    projects.removeAll { $0.id == serverProject.id }
    projects.append(serverProject)
    return serverProject
  }

  func updateProject(_ project: Project) async throws -> ServerProject {
    try await upsertProject(project)
  }

  func deleteProject(id: UUID) async throws {
    if let deleteDelay { await deleteDelay() }
    deletedProjectIDs.append(id.uuidString)
    changed.signal()
    projects.removeAll { $0.id == id.uuidString }
  }

  func listSessions() async throws -> [ServerSession] { sessions }

  func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
    fatalError("unused")
  }

  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    if let sessionUpsertDelay { await sessionUpsertDelay() }
    let serverSession = serverSession(from: session)
    upsertedSessionIDs.append(serverSession.id)
    changed.signal()
    sessions.removeAll { $0.id == serverSession.id }
    sessions.append(serverSession)
    return serverSession
  }

  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    try await upsertSession(session)
  }

  func setSessionAttention(
    id: UUID,
    latestSequence: Int,
    lastSeenSequence: Int
  ) {
    guard let index = sessions.firstIndex(where: { $0.id == id.uuidString }) else {
      return
    }
    sessions[index].latestAttentionSequence = latestSequence
    sessions[index].lastSeenAttentionSequence = lastSeenSequence
    sessions[index].unreadCount = max(0, latestSequence - lastSeenSequence)
  }

  func setReadResponseDelay(_ delay: (@Sendable () async -> Void)?) {
    readResponseDelay = delay
  }

  func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? {
    readRequests.append(FakeReadRequest(sessionId: id, throughSequence: throughSequence))
    changed.signal()
    guard let index = sessions.firstIndex(where: { $0.id == id.uuidString }) else {
      return nil
    }
    let latest = sessions[index].latestAttentionSequence ?? 0
    let requested = min(latest, max(0, throughSequence))
    sessions[index].lastSeenAttentionSequence = max(
      sessions[index].lastSeenAttentionSequence ?? 0,
      requested
    )
    sessions[index].unreadCount = max(
      0,
      latest - (sessions[index].lastSeenAttentionSequence ?? 0)
    )
    let response = sessions[index]
    if let readResponseDelay { await readResponseDelay() }
    return response
  }

  func deleteSession(id: UUID) async throws {
    if let deleteDelay { await deleteDelay() }
    deletedSessionIDs.append(id.uuidString)
    changed.signal()
    sessions.removeAll { $0.id == id.uuidString }
  }

  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }

  func cancelSession(id: UUID) async throws {}

  func setSessionMode(id: UUID, modeId: String) async throws {}

  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}

  nonisolated func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }

  func snapshot() -> FakeServerSnapshot {
    FakeServerSnapshot(
      upsertedProjectIDs: upsertedProjectIDs,
      upsertedSessionIDs: upsertedSessionIDs,
      deletedProjectIDs: deletedProjectIDs,
      deletedSessionIDs: deletedSessionIDs,
      readRequests: readRequests
    )
  }
}

func serverProject(from project: Project) -> ServerProject {
  ServerProject(
    id: project.id.uuidString,
    name: project.name,
    isArchived: project.isArchived,
    origin: project.origin,
    createdAt: serverDateString(from: project.createdAt),
    locations: project.locations.map { location in
      ServerProjectLocation(
        id: location.id,
        projectId: project.id.uuidString,
        serverId: location.serverId,
        folderPath: location.folderPath,
        createdAt: serverDateString(from: project.createdAt),
        isGitRepository: location.isGitRepository
      )
    }
  )
}

func serverSession(from session: ChatSession) -> ServerSession {
  ServerSession(
    id: session.id.uuidString,
    projectId: session.projectId.uuidString,
    serverId: session.serverId,
    harnessId: session.harnessId,
    agentSessionId: session.agentSessionId,
    title: session.title,
    origin: session.origin,
    isArchived: session.isArchived,
    worktreeName: session.worktreeName,
    cwd: session.cwd,
    createdAt: serverDateString(from: session.createdAt),
    updatedAt: session.updatedAt.map(serverDateString),
    sidebarState: session.sidebarState,
    sidebarStateChangedAt: serverDateString(from: session.sidebarStateChangedAt),
    usage: nil,
    latestAttentionSequence: session.latestAttentionSequence,
    lastSeenAttentionSequence: session.lastSeenAttentionSequence,
    unreadCount: session.unreadCount,
    hasUnreadError: session.hasUnreadError
  )
}

func serverDateString(from date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
