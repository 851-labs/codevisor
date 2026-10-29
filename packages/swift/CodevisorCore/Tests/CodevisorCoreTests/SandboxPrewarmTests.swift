import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Starting a sandbox before the first send")
struct SandboxPrewarmTests {
  @Test("Picking a VM starts creating it at once, with no workspace until the send claims one")
  func pickingStartsCreating() async {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)

    controller.sandboxTarget = .tartVM
    let request = await client.nextCreate()

    #expect(request.profileId == "profile-tart")
    #expect(request.projectId == controller.project.id)
    #expect(request.workspaceId == nil)
    #expect(controller.sandboxPrewarm?.machineId == request.id)
  }

  @Test("Picking another machine tears the early VM down like a failed setup")
  func abandoningDestroys() async {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)
    controller.sandboxTarget = .tartVM
    let created = await client.nextCreate()

    controller.sandboxTarget = nil

    #expect(await client.nextDestroy() == created.id)
    #expect(controller.sandboxPrewarm == nil)
  }

  @Test("The send adopts the early VM instead of starting another")
  func sendAdoptsPrewarm() async throws {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)
    controller.sandboxTarget = .tartVM
    let created = await client.nextCreate()

    let adopted = try #require(controller.takeSandboxPrewarm(for: .tartVM, client: client))

    #expect(adopted.machineId == created.id)
    #expect(controller.sandboxPrewarm == nil)
    #expect(client.createCount == 1)
  }

  @Test("Changes made while the first send starts leave the early VM for that send")
  func firstSendKeepsPrewarm() async throws {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client)
    controller.sandboxTarget = .tartVM
    let created = await client.nextCreate()

    controller.hasSentFirst = true
    controller.project = controller.project
    let adopted = try #require(controller.takeSandboxPrewarm(for: .tartVM, client: client))

    #expect(adopted.machineId == created.id)
    #expect(client.createCount == 1)
  }

  @Test("Without a project there is nothing to start early")
  func scratchProjectsWait() {
    let client = PrewarmFakeServerClient()
    let controller = makeController(client: client, scratch: true)

    controller.sandboxTarget = .tartVM

    #expect(controller.sandboxPrewarm == nil)
    #expect(controller.takeSandboxPrewarm(for: .tartVM, client: client) == nil)
  }

  @Test("A full Mac blocks Send and says the profile is full, not broken")
  func fullMacWaits() async {
    let client = PrewarmFakeServerClient()
    client.availabilityReason = "This Mac already runs 2 macOS VMs"
    client.availabilityIsFull = true
    let machines = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel.fixture(), clientFactory: { _ in client })
    let controller = makeController(client: client, machines: machines)
    await machines.sandboxProfiles.load(composerId: "local", from: client) { _ in .unreachable }

    controller.sandboxTarget = .tartVM

    #expect(!controller.acceptsSends)
    #expect(controller.isSandboxTargetFull)
    #expect(controller.sandboxUnavailableMessage == "macOS VM is full. This Mac already runs 2 macOS VMs.")
    #expect(controller.sandboxPrewarm == nil)
  }

  @Test("A VM that can't start blocks Send, then starts once its Mac can run it")
  func unavailableVMWaits() async {
    let client = PrewarmFakeServerClient()
    client.availabilityReason = "Only 30.0 GB of disk is free on this Mac; a Tart VM needs 40 GB"
    let machines = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel.fixture(), clientFactory: { _ in client })
    let controller = makeController(client: client, machines: machines)
    await machines.sandboxProfiles.load(composerId: "local", from: client) { _ in .unreachable }

    controller.sandboxTarget = .tartVM

    #expect(!controller.acceptsSends)
    #expect(!controller.isSandboxTargetFull)
    #expect(
      controller.sandboxUnavailableMessage
        == "macOS VM can't start. Only 30.0 GB of disk is free on this Mac; a Tart VM needs 40 GB.")
    #expect(controller.sandboxPrewarm == nil)

    client.availabilityReason = nil
    await machines.sandboxProfiles.load(composerId: "local", from: client) { _ in .unreachable }
    controller.refreshSandboxPrewarm()

    #expect(controller.acceptsSends)
    #expect(controller.sandboxUnavailableMessage == nil)
    #expect(await client.nextCreate().profileId == "profile-tart")
  }

  @Test("The picked VM's row spins exactly when Send waits on its check")
  func pickedRowMatchesSend() async {
    let client = PrewarmFakeServerClient()
    let machines = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel.fixture(), clientFactory: { _ in client })
    let controller = makeController(client: client, machines: machines)
    controller.sandboxTarget = .tartVM

    let unchecked = controller.presentedSandboxChoices(machines.sandboxProfiles.choices(for: "local"))
    #expect(unchecked.isEmpty)
    let pending = controller.presentedSandboxChoices([SandboxProfileChoice(target: .tartVM, availability: .checking)])
    #expect(pending.map(\.availability) == [.checking])
    #expect(!controller.acceptsSends)

    await machines.sandboxProfiles.load(composerId: "local", from: client) { _ in .unreachable }
    controller.refreshSandboxPrewarm()
    _ = await client.nextCreate()
    let recheck = [SandboxProfileChoice(target: .tartVM, availability: .checking)]

    #expect(controller.presentedSandboxChoices(recheck).map(\.availability) == [.available])
    #expect(controller.acceptsSends)
  }

  private func makeController(
    client: PrewarmFakeServerClient, scratch: Bool = false, machines: MachineController? = nil
  ) -> SessionController {
    var project = Project.fromFolder(URL(fileURLWithPath: "/tmp/hello-world"), serverId: "local")
    project.isScratch = scratch
    return SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: ComposerDefaultsStore(store: InMemoryStore()),
      serverClient: client,
      machines: machines
    )
  }
}

private final class PrewarmFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var creates = 0
  private var reason: String?
  private var reasonIsFull = false
  private let createdStream: AsyncStream<ServerSandboxRequest>
  private let createdContinuation: AsyncStream<ServerSandboxRequest>.Continuation
  private let destroyedStream: AsyncStream<String>
  private let destroyedContinuation: AsyncStream<String>.Continuation

  init() {
    (createdStream, createdContinuation) = AsyncStream.makeStream()
    (destroyedStream, destroyedContinuation) = AsyncStream.makeStream()
  }

  var createCount: Int { lock.withLock { creates } }

  var availabilityReason: String? {
    get { lock.withLock { reason } }
    set { lock.withLock { reason = newValue } }
  }

  var availabilityIsFull: Bool {
    get { lock.withLock { reasonIsFull } }
    set { lock.withLock { reasonIsFull = newValue } }
  }

  func sandboxVendors() async throws -> ServerSandboxVendors { ServerSandboxVendors() }

  func sandboxProviders() async throws -> [ServerSandboxProvider] { [] }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    [.init(id: "profile-tart", name: "macOS VM", vendor: "tart", providerId: "tart-local")]
  }

  func sandboxAvailability() async throws -> [ServerSandboxAvailability] {
    [.init(profileId: "profile-tart", disabledReason: availabilityReason, full: availabilityIsFull ? true : nil)]
  }

  func nextCreate() async -> ServerSandboxRequest {
    var iterator = createdStream.makeAsyncIterator()
    guard let request = await iterator.next() else { preconditionFailure("The create stream ended") }
    return request
  }

  func nextDestroy() async -> String? {
    var iterator = destroyedStream.makeAsyncIterator()
    return await iterator.next()
  }

  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    lock.withLock { creates += 1 }
    createdContinuation.yield(request)
    return ServerSandbox(id: request.id, vendor: "tart", name: "Tart", state: "creating")
  }

  func destroySandbox(id: String) async throws {
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
