import ACPKit
import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MachineReconnectTests {
  @Test("A machine that can't be reached says connecting while it retries, keeps its stale state, and recovers")
  func failedMachineReconnects() async throws {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)

    await fixture.controller.prepareMachine(remote.id)
    guard case .failed = fixture.controller.availabilityByMachineId[remote.id] else {
      Issue.record("A failed connection should surface as failed availability")
      return
    }
    let failure = try #require(fixture.controller.navigationSyncStateByMachineId[remote.id])
    guard case .stale = failure else {
      Issue.record("A failed connection should keep its connection warning visible")
      return
    }
    await #expect(throws: ServerRequestGateError.self) {
      try await fixture.controller.requestGate.waitUntilReady(for: remote.id)
    }

    let probeStarted = TestSignal()
    let probeGate = TestSignal()
    fixture.fake.setInfoDelay {
      probeStarted.signal()
      await probeGate.wait()
    }
    fixture.fake.setInfoFails(false)
    await fixture.advanceToRetry(after: MachineReconnector.baseDelay)
    await probeStarted.wait()
    #expect(fixture.controller.availabilityByMachineId[remote.id] == .waiting(.connecting))
    #expect(fixture.controller.navigationSyncStateByMachineId[remote.id] == failure)
    probeGate.signal()

    await awaitObserved { fixture.controller.navigationSyncStateByMachineId[remote.id] == .current }
    #expect(fixture.controller.availabilityByMachineId[remote.id] == .ready)
    try await fixture.controller.requestGate.waitUntilReady(for: remote.id)
  }

  @Test("Each failed attempt waits longer before the next, up to the cap")
  func retriesBackOff() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)

    await fixture.controller.prepareMachine(remote.id)
    for delay in [1, 2, 4, 8, 15, 15] { await fixture.advanceToRetry(after: .seconds(delay)) }

    #expect(Array(fixture.retryDelays.prefix(6)) == [1, 2, 4, 8, 15, 15].map { Duration.seconds($0) })
  }

  @Test("Checking connections retries a failed machine at once instead of waiting out its backoff")
  func verifyingRetriesAtOnce() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)
    await fixture.controller.prepareMachine(remote.id)
    await fixture.advanceToRetry(after: .seconds(1))
    await awaitObserved { fixture.retryDelays.count == 2 }

    fixture.fake.setInfoFails(false)
    fixture.controller.verifyConnections()

    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .ready }
    #expect(fixture.retryDelays == [.seconds(1), .seconds(2)])
  }

  @Test("A connection loss reported by any request reconnects a connected machine")
  func reportedLossReconnects() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)

    fixture.controller.requestGate.reportConnectionLost(for: remote.id)

    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] != .ready }
    await awaitObserved { fixture.retryDelays == [.seconds(1)] }
    fixture.fake.setInfoFails(false)
    await fixture.advanceToRetry(after: .seconds(1))
    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .ready }
  }

  @Test("A machine that drops again soon after reconnecting waits before the next attempt")
  func flappingBacksOff() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()

    await fixture.controller.prepareMachine(remote.id)
    fixture.controller.connectionLost(machineId: remote.id)

    #expect(fixture.controller.availabilityByMachineId[remote.id] == .waiting(.connecting))
    await fixture.advanceToRetry(after: .seconds(1))
    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .ready }
  }

  @Test("Going offline marks remote machines offline at once, and coming back reconnects them")
  func deviceOfflineAndBack() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)

    fixture.controller.deviceNetworkChanged(isOnline: false)

    await awaitObserved {
      fixture.controller.availabilityByMachineId[remote.id] == .failed(MachineController.deviceOfflineMessage)
    }
    #expect(fixture.controller.availabilityByMachineId[CodevisorMachine.local.id] == .ready)

    fixture.fake.setInfoFails(false)
    fixture.controller.deviceNetworkChanged(isOnline: true)
    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .ready }
  }

  @Test("The cloud saying a machine went offline or came back checks it right away")
  func cloudPresenceChecksTheMachine() async {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)

    fixture.provider?.cloudMachines = [makeCloudMachine(deviceId: "remote-box", name: "remote-box", online: false)]
    fixture.controller.applyCloudPresence()
    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .failed("remote-box is offline") }

    fixture.fake.setInfoFails(false)
    fixture.provider?.cloudMachines = [makeCloudMachine(deviceId: "remote-box", name: "remote-box")]
    fixture.controller.applyCloudPresence()
    await awaitObserved { fixture.controller.availabilityByMachineId[remote.id] == .ready }
  }

  @Test("Pruning a cloud twin stops the reconnect it still had scheduled")
  func pruningTwinStopsItsReconnect() async {
    let fixture = ReconnectFixture()
    let twinId = CodevisorMachine.cloudIdPrefix + "twin-device"
    _ = signIn(fixture.controller, machines: [accountMachine("twin-device")])
    fixture.fake.setInfoFails(true)
    await fixture.controller.prepareMachine(twinId)
    let twin = fixture.controller.connection(for: twinId)
    #expect(twin.reconnector.isActive)

    fixture.controller.pruneCloudTwinRecords(deviceId: "twin-device")

    #expect(fixture.controller.connectionsById[twinId] == nil)
    #expect(!twin.reconnector.isActive)
  }

  @Test("Retrying a machine by hand reconnects it at once")
  func explicitRetryReconnects() async throws {
    let fixture = ReconnectFixture()
    defer { fixture.controller.stopEventSync() }
    let remote = fixture.signIn()
    fixture.fake.setInfoFails(true)
    await fixture.controller.prepareMachine(remote.id)

    fixture.fake.setInfoFails(false)
    await fixture.controller.retryMachine(remote.id)

    try await fixture.controller.requestGate.waitUntilReady(for: remote.id)
    #expect(fixture.controller.navigationSyncStateByMachineId[remote.id] == .current)
  }

  @Test("A local server that won't start keeps being retried, never given up on")
  func failedLocalServerRetries() async {
    let local = StubLocalServer()
    local.state = .unavailable("The server didn't start")
    let fixture = ReconnectFixture(localServer: local)
    defer { fixture.controller.stopEventSync() }

    await fixture.controller.prepareMachine("local")
    guard case .failed = fixture.controller.availabilityByMachineId["local"] else {
      Issue.record("A local server that won't start should surface as failed availability")
      return
    }

    local.state = .started
    await fixture.advanceToRetry(after: .seconds(1))
    await awaitObserved { fixture.controller.availabilityByMachineId["local"] == .ready }
  }
}

@MainActor
private final class ReconnectFixture {
  static let noticeDelay: Duration = .seconds(3600)

  let fake = PreparationFakeServerClient()
  let scheduler = ManualSessionConnectionRecoveryScheduler()
  let controller: MachineController
  private(set) var provider: FakeCloudProvider?
  private var advancedRetries = 0

  init(localServer: (any LocalServerControlling)? = nil) {
    let fake = fake
    controller = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel.fixture(), localServer: localServer,
      clientFactory: { _ in fake }, reconnectNoticeDelay: Self.noticeDelay, connectionScheduler: scheduler.scheduler)
  }

  var retryDelays: [Duration] {
    scheduler.requestedIntervals.filter { $0 != Self.noticeDelay }
  }

  func signIn() -> CodevisorMachine {
    let remote = accountMachine("remote-box")
    provider = CodevisorCoreTests.signIn(controller, machines: [remote])
    return remote
  }

  func advanceToRetry(after delay: Duration) async {
    await awaitObserved { retryDelays.count > advancedRetries }
    #expect(retryDelays[advancedRetries] == delay)
    advancedRetries += 1
    scheduler.advance()
  }
}

private final class PreparationFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
  private struct InfoFailure: Error {}

  private let lock = NSLock()
  private var infoFails = false

  private var infoDelay: (@Sendable () async -> Void)?
  private var snapshotDelay: (@Sendable () async -> Void)?

  func setInfoDelay(_ delay: @escaping @Sendable () async -> Void) {
    lock.withLock { infoDelay = delay }
  }

  func setSnapshotDelay(_ delay: @escaping @Sendable () async -> Void) {
    lock.withLock { snapshotDelay = delay }
  }

  func setInfoFails(_ fails: Bool) {
    lock.withLock { infoFails = fails }
  }

  func info() async throws -> ServerInfo {
    if let delay = lock.withLock({ infoDelay }) { await delay() }
    if lock.withLock({ infoFails }) { throw InfoFailure() }
    return ServerInfo(
      id: "remote", name: "Remote", kind: "remote", version: "0.1.0",
      platform: "darwin", bindHost: "0.0.0.0"
    )
  }

  func health() async throws -> ServerHealth {
    ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
  }

  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    ServerUpdateInfo(
      currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
      channel: "stable", checkedAt: nil, migrationState: "idle"
    )
  }

  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] {
    if let delay = lock.withLock({ snapshotDelay }) { await delay() }
    return []
  }
  func latestShellEventCursor() async throws -> Int { 0 }

  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }

  func capabilities(cwd: String) async throws -> ServerCapabilities {
    ServerCapabilities(harnesses: [])
  }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    fatalError("unused")
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
