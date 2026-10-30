import CodevisorClient
import CodevisorCloud
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Sending to a chat whose sandbox is paused", .timeLimit(.minutes(1)))
struct SessionControllerSandboxWakeTests {
  @Test("A window that never reached the paused sandbox wakes it on send and delivers the message once")
  func sendFromAWindowThatNeverConnected() async throws {
    let fixture = try WakeFixture()
    defer { fixture.tearDown() }
    await fixture.machines.loadSandboxMachineProfiles()
    fixture.chat.openSessionFailure = .httpStatus(503, "unreachable")
    await fixture.controller.connectIfNeeded()

    fixture.controller.composerText = "wake up"
    await fixture.controller.send()
    await fixture.owner.wakes.wait()
    #expect(fixture.controller.sendReadiness == .waking(failure: SessionController.sandboxWakeFailure))

    fixture.chat.openSessionFailure = nil
    fixture.comeOnline()
    fixture.finishWake()
    await fixture.machines.loadSandboxMachineProfiles()
    await fixture.chat.promptRequests.wait()
    await awaitObserved { !fixture.controller.hasUnsentMessages }

    #expect(fixture.chat.promptedTexts == ["wake up"])
    #expect(fixture.owner.wokenIds == ["sbx"])
  }

  @Test("A woken sandbox that is back online holds the message until its owner says the wake finished")
  func sendWaitsForTheOwnerToFinishTheWake() async throws {
    let fixture = try WakeFixture()
    defer { fixture.tearDown() }
    await fixture.machines.loadSandboxMachineProfiles()
    fixture.chat.openSessionFailure = .httpStatus(503, "unreachable")
    await fixture.controller.connectIfNeeded()

    fixture.controller.composerText = "wake up"
    await fixture.controller.send()
    await fixture.owner.wakes.wait()
    fixture.chat.openSessionFailure = nil
    fixture.comeOnline()
    await fixture.machines.loadSandboxMachineProfiles()

    #expect(fixture.controller.sandboxPower == .waking)
    #expect(fixture.controller.sendReadiness == .waking(failure: SessionController.sandboxWakeFailure))

    fixture.finishWake()
    await fixture.machines.loadSandboxMachineProfiles()
    await fixture.chat.promptRequests.wait()
    await awaitObserved { !fixture.controller.hasUnsentMessages }
    #expect(fixture.chat.promptedTexts == ["wake up"])
  }

  @Test("A send to an awake sandbox asks its owner to keep it up, so it can't idle-pause before delivery")
  func sendToAnAwakeSandboxKeepsItUp() async throws {
    let fixture = try WakeFixture()
    defer { fixture.tearDown() }
    fixture.comeOnline()
    fixture.finishWake()
    await fixture.machines.loadSandboxMachineProfiles()
    await fixture.controller.connectIfNeeded()

    fixture.controller.composerText = "still there?"
    await fixture.controller.send()
    await fixture.owner.wakes.wait()
    await fixture.chat.promptRequests.wait()

    #expect(fixture.owner.wokenIds == ["sbx"])
    #expect(fixture.chat.promptedTexts == ["still there?"])
  }

  @Test("The saved history stays on screen while the woken chat reconnects")
  func savedHistoryOutlivesTheWake() async throws {
    let fixture = try WakeFixture()
    defer { fixture.tearDown() }
    await fixture.machines.loadSandboxMachineProfiles()
    fixture.chat.openSessionFailure = .httpStatus(503, "unreachable")
    await fixture.controller.connectIfNeeded()
    #expect(fixture.userTexts() == ["saved"])

    fixture.controller.composerText = "wake up"
    await fixture.controller.send()
    await fixture.owner.wakes.wait()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    fixture.chat.openSessionGate = gate
    defer { release.finish() }
    fixture.chat.openSessionFailure = nil
    fixture.comeOnline()
    fixture.finishWake()
    await fixture.machines.loadSandboxMachineProfiles()
    await fixture.chat.openSessionRequests.wait()
    await fixture.chat.openSessionRequests.wait()

    #expect(fixture.userTexts() == ["saved"])
    release.finish()
    await fixture.chat.promptRequests.wait()
    #expect(fixture.userTexts().first == "fresh")
  }

  @Test("A message waiting on the wake outlives its window and the chat reopens with it, until it goes out")
  func pendingSendOutlivesItsWindow() async throws {
    let fixture = try WakeFixture()
    defer { fixture.tearDown() }
    let holder = PendingSendHolder()
    var closingWindow: NSObject? = NSObject()
    let otherWindow = NSObject()
    holder.track(fixture.controller, ownedBy: try #require(closingWindow))
    await fixture.machines.loadSandboxMachineProfiles()

    fixture.controller.composerText = "wake up"
    await fixture.controller.send()
    await fixture.owner.wakes.wait()
    #expect(holder.adopt(serverId: fixture.sandbox.id, sessionId: fixture.sessionId, by: otherWindow) == nil)

    closingWindow = nil
    let reopened = holder.adopt(serverId: fixture.sandbox.id, sessionId: fixture.sessionId, by: otherWindow)
    #expect(reopened === fixture.controller)
    holder.track(fixture.controller, ownedBy: otherWindow)

    fixture.comeOnline()
    fixture.finishWake()
    await fixture.machines.loadSandboxMachineProfiles()
    await fixture.chat.promptRequests.wait()
    await awaitObserved { !fixture.controller.hasUnsentMessages }
    #expect(holder.adopt(serverId: fixture.sandbox.id, sessionId: fixture.sessionId, by: NSObject()) == nil)
    #expect(fixture.chat.promptedTexts == ["wake up"])
  }
}

@MainActor
private final class WakeFixture {
  let sessionId = UUID()
  let ownerMachine = accountMachine("owner")
  let sandbox = accountMachine("sandbox")
  let owner = WakeOwnerFakeServerClient()
  let chat: FakeSessionServerClient
  let machines: MachineController
  let provider: FakeCloudProvider
  let controller: SessionController
  let cacheDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)

  init() throws {
    machines = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel.fixture(), clientFactory: { [owner] _ in owner })
    provider = signIn(machines, machines: [ownerMachine, sandbox])
    provider.cloudMachines = provider.cloudMachines.map { machine in
      guard machine.deviceId == "sandbox" else { return machine }
      var marked = machine
      marked.ephemeral = CloudEphemeralOrigin(provider: "modal", ownerDeviceId: "owner")
      marked.online = false
      return marked
    }
    machines.markFailed(for: sandbox.id, message: "offline")

    let project = Project.fromFolder(URL(fileURLWithPath: "/home/codevisor/project"), serverId: sandbox.id)
    chat = FakeSessionServerClient(sessionId: sessionId)
    chat.openSessionResponse = try JSONDecoder().decode(
      ServerSessionOpenResponse.self, from: Self.openResponse(sessionId: sessionId, serverId: sandbox.id, text: "fresh")
    )
    let cache = TranscriptPageCache(directory: cacheDirectory)
    cache.store(
      Self.openResponse(sessionId: sessionId, serverId: sandbox.id, text: "saved"), machineId: sandbox.id,
      sessionId: sessionId)
    controller = SessionController(
      project: project, configCache: ConfigOptionCache(store: InMemoryStore()), serverClient: chat,
      machines: machines)
    controller.transcriptCache = cache
    controller.configureExistingSession(
      ChatSession(
        id: sessionId, projectId: project.id, serverId: sandbox.id, harnessId: "codex", agentSessionId: "agent-1",
        title: "Paused chat", createdAt: Date(timeIntervalSince1970: 1)))
  }

  func finishWake() {
    owner.power = nil
  }

  func comeOnline() {
    provider.cloudMachines = provider.cloudMachines.map { machine in
      guard machine.deviceId == "sandbox" else { return machine }
      var online = machine
      online.online = true
      return online
    }
    machines.markReady(for: sandbox.id)
  }

  func userTexts() -> [String] {
    (controller.model?.conversation ?? []).compactMap { item in
      guard case .user(let user) = item else { return nil }
      return user.text
    }
  }

  func tearDown() {
    controller.model?.shutdown()
    try? FileManager.default.removeItem(at: cacheDirectory)
  }

  static func openResponse(sessionId: UUID, serverId: String, text: String) -> Data {
    Data(
      """
      {
        "session": {
          "id": "\(sessionId.uuidString)", "projectId": "\(UUID().uuidString)", "serverId": "\(serverId)",
          "harnessId": "codex", "agentSessionId": "agent-1", "title": "Paused chat", "origin": "codevisor",
          "createdAt": "2026-09-08T17:45:00Z"
        },
        "transcript": {
          "items": [
            {
              "id": "\(UUID().uuidString)", "sessionId": "\(sessionId.uuidString)", "sequence": 0,
              "role": "user", "text": "\(text)", "createdAt": "2026-09-08T17:45:00.000Z",
              "updatedAt": "2026-09-08T17:45:00.000Z", "isGenerating": false, "hasDetails": false,
              "revision": 1
            }
          ],
          "setupActivities": [], "stateUpdates": [], "hasNewer": false, "hasMore": false, "eventCursor": 1
        }
      }
      """.utf8)
  }
}

private final class WakeOwnerFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var _power: String? = "paused"
  private var _wokenIds: [String] = []
  let wakes = TestSignal()

  var wokenIds: [String] { lock.withLock { _wokenIds } }

  var power: String? {
    get { lock.withLock { _power } }
    set { lock.withLock { _power = newValue } }
  }

  func sandboxes() async throws -> [ServerSandbox] {
    [
      ServerSandbox(
        id: "sbx", vendor: "modal", name: "Modal", state: "ready", profileId: "modal", deviceId: "sandbox",
        power: power)
    ]
  }

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    [ServerSandboxProfile(id: "modal", name: "Modal", vendor: "modal")]
  }

  func wakeSandbox(id: String) async throws -> ServerSandbox {
    lock.withLock {
      if _power == "paused" { _power = "waking" }
      _wokenIds.append(id)
    }
    wakes.signal()
    return try await sandboxes()[0]
  }

  func info() async throws -> ServerInfo {
    ServerInfo(id: "owner", name: "Owner", kind: "local", version: "0.1.0", platform: "darwin", bindHost: "0.0.0.0")
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
