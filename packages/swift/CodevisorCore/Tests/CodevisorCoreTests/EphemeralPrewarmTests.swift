import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Starting an ephemeral machine before the first send")
struct EphemeralPrewarmTests {
  @Test("Picking a VM starts creating it at once, with no workspace until the send claims one")
  func pickingStartsCreating() async {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)

    controller.ephemeralTarget = .provider("tart")
    let request = await client.nextCreate()

    #expect(request.provider == "tart")
    #expect(request.projectId == controller.project.id)
    #expect(request.workspaceId == nil)
    #expect(controller.ephemeralPrewarm?.machineId == request.id)
  }

  @Test("Picking another machine tears the early VM down like a failed setup")
  func abandoningDestroys() async {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)
    controller.ephemeralTarget = .provider("tart")
    let created = await client.nextCreate()

    controller.ephemeralTarget = nil

    #expect(await client.nextDestroy() == created.id)
    #expect(controller.ephemeralPrewarm == nil)
  }

  @Test("The send adopts the early VM instead of starting another")
  func sendAdoptsPrewarm() async throws {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)
    controller.ephemeralTarget = .provider("tart")
    let created = await client.nextCreate()

    let adopted = try #require(controller.takeEphemeralPrewarm(for: .provider("tart"), client: client))

    #expect(adopted.machineId == created.id)
    #expect(controller.ephemeralPrewarm == nil)
    #expect(client.createCount == 1)
  }

  @Test("Without a project there is nothing to start early")
  func scratchProjectsWait() {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client, scratch: true)

    controller.ephemeralTarget = .provider("tart")

    #expect(controller.ephemeralPrewarm == nil)
    #expect(controller.takeEphemeralPrewarm(for: .provider("tart"), client: client) == nil)
  }

  private func makeController(client: PrewarmFakeServerClient, scratch: Bool = false) -> SessionController {
    var project = Project.fromFolder(URL(fileURLWithPath: "/tmp/hello-world"), serverId: "local")
    project.isScratch = scratch
    return SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: ComposerDefaultsStore(store: InMemoryStore()),
      serverClient: client
    )
  }
}

private final class PrewarmFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var creates = 0
  private let createdStream: AsyncStream<ServerEphemeralMachineRequest>
  private let createdContinuation: AsyncStream<ServerEphemeralMachineRequest>.Continuation
  private let destroyedStream: AsyncStream<String>
  private let destroyedContinuation: AsyncStream<String>.Continuation

  init() {
    (createdStream, createdContinuation) = AsyncStream.makeStream()
    (destroyedStream, destroyedContinuation) = AsyncStream.makeStream()
  }

  var createCount: Int { lock.withLock { creates } }

  func nextCreate() async -> ServerEphemeralMachineRequest {
    var iterator = createdStream.makeAsyncIterator()
    guard let request = await iterator.next() else { preconditionFailure("The create stream ended") }
    return request
  }

  func nextDestroy() async -> String? {
    var iterator = destroyedStream.makeAsyncIterator()
    return await iterator.next()
  }

  func createEphemeralMachine(_ request: ServerEphemeralMachineRequest) async throws -> ServerEphemeralMachine {
    lock.withLock { creates += 1 }
    createdContinuation.yield(request)
    return ServerEphemeralMachine(id: request.id, provider: request.provider, name: "Tart", state: "creating")
  }

  func destroyEphemeralMachine(id: String) async throws {
    destroyedContinuation.yield(id)
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "local", name: "Local", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
  }
  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle")
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { fatalError("unused") }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
