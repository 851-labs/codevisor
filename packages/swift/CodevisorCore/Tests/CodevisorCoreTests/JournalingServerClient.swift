import ACPKit
import CodevisorClient
import Foundation

@testable import CodevisorCore

final class JournalingServerClient: CodevisorServerClienting, @unchecked Sendable {
  let base: FakeServerClient
  private let lock = NSLock()
  private var cursor = 100

  init(_ base: FakeServerClient) { self.base = base }

  private func journaled<T>(_ write: () async throws -> T) async rethrows -> T {
    let result = try await write()
    lock.withLock { cursor += 1 }
    return result
  }

  func latestShellEventCursor() async throws -> Int { lock.withLock { cursor } }

  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    let cursor = lock.withLock { self.cursor }
    return ServerNavigationSnapshot(
      eventCursor: cursor, projects: try await base.listProjects(), sessions: try await base.listSessions(),
      workspaces: [], panes: [])
  }

  func upsertProject(_ project: Project) async throws -> ServerProject {
    try await journaled { try await base.upsertProject(project) }
  }
  func updateProject(_ project: Project) async throws -> ServerProject {
    try await journaled { try await base.updateProject(project) }
  }
  func deleteProject(id: UUID) async throws { try await journaled { try await base.deleteProject(id: id) } }
  func deleteProject(id: UUID, deletingFiles: Bool) async throws {
    try await journaled { try await base.deleteProject(id: id, deletingFiles: deletingFiles) }
  }
  func updateProjectWorktreeBase(id: UUID, worktreeBase: ProjectWorktreeBase?) async throws -> ServerProject {
    try await journaled { try await base.updateProjectWorktreeBase(id: id, worktreeBase: worktreeBase) }
  }

  func updateProjectDefaultRunLocation(
    id: UUID, defaultRunLocation: ProjectRunLocation?
  ) async throws -> ServerProject {
    try await journaled {
      try await base.updateProjectDefaultRunLocation(id: id, defaultRunLocation: defaultRunLocation)
    }
  }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    try await journaled { try await base.upsertSession(session) }
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    try await journaled { try await base.updateSession(session) }
  }
  func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? {
    try await journaled { try await base.markSessionRead(id: id, throughSequence: throughSequence) }
  }
  func markSessionUnread(id: UUID) async throws -> ServerSession? {
    try await journaled { try await base.markSessionUnread(id: id) }
  }
  func deleteSession(id: UUID) async throws { try await journaled { try await base.deleteSession(id: id) } }

  func listProjects() async throws -> [ServerProject] { try await base.listProjects() }
  func listSessions() async throws -> [ServerSession] { try await base.listSessions() }
  func health() async throws -> ServerHealth { try await base.health() }
  func info() async throws -> ServerInfo { try await base.info() }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    try await base.updateInfo(refresh: refresh, channel: channel)
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { try await base.capabilities(cwd: cwd) }
  func listHarnesses() async throws -> [ServerHarness] { try await base.listHarnesses() }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    try await base.promptSession(id: id, text: text)
  }
  func cancelSession(id: UUID) async throws { try await base.cancelSession(id: id) }
  func setSessionMode(id: UUID, modeId: String) async throws { try await base.setSessionMode(id: id, modeId: modeId) }
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {
    try await base.setSessionConfig(id: id, configId: configId, value: value)
  }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    base.eventStream(since: since)
  }
}

@MainActor private var journals: [ObjectIdentifier: JournalingServerClient] = [:]

@MainActor
func journaled(_ client: any CodevisorServerClienting) -> any CodevisorServerClienting {
  guard let fake = client as? FakeServerClient else { return client }
  if let existing = journals[ObjectIdentifier(fake)] { return existing }
  let journal = JournalingServerClient(fake)
  journals[ObjectIdentifier(fake)] = journal
  return journal
}
