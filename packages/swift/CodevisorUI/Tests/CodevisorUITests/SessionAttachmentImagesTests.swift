import CodevisorClient
import CodevisorCore
import Foundation
import Testing

@testable import CodevisorUI

@Suite("Chat attachment images")
@MainActor
struct SessionAttachmentImagesTests {
  @Test("A sub-agent pane reads its files through the parent chat's session")
  func subagentReadsThroughParent() async throws {
    let client = SessionFileClient()
    let parent = chat(client: client, cwd: "/tmp/parent-worktree")
    let mirror = SubagentMirror(parent: parent, toolCallId: "task-1")

    let data = try await SessionAttachmentImages.store(for: mirror.controller).data(for: .serverPath("shot.png"))

    #expect(data == Data("shot.png".utf8))
    #expect(client.reads == [SessionFileRead(sessionId: parent.serverSession?.id, path: "shot.png")])
    #expect(SessionAttachmentImages.store(for: mirror.controller) === SessionAttachmentImages.store(for: parent))
  }

  @Test("Every view of a chat shares its store until the chat moves to another folder")
  func storeFollowsTheChatsFolder() {
    let first = chat(client: SessionFileClient(), cwd: "/tmp/first")
    let other = chat(client: SessionFileClient(), cwd: "/tmp/other")
    let store = SessionAttachmentImages.store(for: first)

    #expect(SessionAttachmentImages.store(for: first) === store)
    #expect(SessionAttachmentImages.store(for: other) !== store)

    first.serverSession?.cwd = "/tmp/first-worktree"
    let moved = SessionAttachmentImages.store(for: first)

    #expect(moved !== store)
    #expect(moved.namespace == first.previewCacheNamespace)
  }

  private func chat(client: SessionFileClient, cwd: String) -> SessionController {
    let project = Project.fromFolder(URL(fileURLWithPath: cwd))
    let controller = SessionController(
      project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: client)
    controller.serverSession = ChatSession(projectId: project.id, cwd: cwd)
    return controller
  }
}

private struct SessionFileRead: Equatable {
  let sessionId: UUID?
  let path: String
}

private final class SessionFileClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var _reads: [SessionFileRead] = []

  var reads: [SessionFileRead] { lock.withLock { _reads } }

  func fileData(sessionId: UUID, path: String) async throws -> Data {
    lock.withLock { _reads.append(SessionFileRead(sessionId: sessionId, path: path)) }
    return Data(path.utf8)
  }

  func health() async throws -> ServerHealth { throw CodevisorServerClientError.invalidResponse }
  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    ServerNavigationSnapshot(eventCursor: 0, projects: [], sessions: [], workspaces: [], panes: [])
  }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
