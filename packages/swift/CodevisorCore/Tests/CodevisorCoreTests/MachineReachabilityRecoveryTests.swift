import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Machine reachability recovery")
struct MachineReachabilityRecoveryTests {
  private func chat(
    on machines: MachineController, machineId: String,
    client: FakeSessionServerClient = FakeSessionServerClient(sessionId: UUID())
  ) -> SessionController {
    let sessionId = client.sessionId
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: machineId),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: client,
      machines: machines
    )
    controller.model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    return controller
  }

  @Test("A chat whose machine goes away says nothing, and the machine reads as quiet rather than failed")
  func chatStaysQuietForAnAwayMachine() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, connectionScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    let provider = signIn(machines, machines: [studio])
    provider.cloudMachines = [makeCloudMachine(deviceId: "studio", name: "Mac Studio", online: false)]
    let controller = chat(on: machines, machineId: studio.id)

    machines.markFailed(for: studio.id, message: "Offline")
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { machines.showsReconnectNotice(for: studio.id) }

    #expect(controller.transcriptActivityOverride == nil)
    #expect(machines.reach(for: studio.id) == .quiet)
  }

  @Test("A message waiting on its machine shows the progress bar, and nothing else, once the machine is away")
  func pendingMessageShowsProgressWhileReconnecting() async throws {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, connectionScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    let client = FakeSessionServerClient(sessionId: UUID())
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdPrompts(until: gate)
    defer { release.finish() }
    let controller = chat(on: machines, machineId: studio.id, client: client)
    let model = try #require(controller.model)
    model.sendingNoticeDelay = .seconds(3600)
    Task { await model.send("warm up") }
    await client.promptRequests.wait()
    let message = UserMessage(text: "still there?")
    Task { await model.send(message) }
    await client.promptRequests.wait(for: 2)
    #expect(controller.transcriptProjectionInput.deliveries[message.id] == nil)

    machines.markFailed(for: studio.id, message: "Offline")
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()

    await awaitObserved { controller.transcriptProjectionInput.deliveries[message.id] == .sending }
    #expect(controller.transcriptActivityOverride == nil)
  }

  @Test("A new turn waiting on its machine shows only the message and its progress, and starts working once sent")
  func newTurnWaitsQuietlyForTheConnection() async throws {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, connectionScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    let client = FakeSessionServerClient(sessionId: UUID())
    client.echoOnPrompt = false
    client.sendAttempts.failuresLeft = 1
    let (reconnection, reconnect) = AsyncStream.makeStream(of: Void.self)
    client.sendAttempts.reconnection = reconnection
    defer { reconnect.finish() }
    let controller = chat(on: machines, machineId: studio.id, client: client)
    let time = TurnClock()
    controller.model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: client.sessionId),
      sessionId: client.sessionId.uuidString, now: { time.now })
    let model = try #require(controller.model)
    model.sendingNoticeDelay = .seconds(3600)
    machines.markFailed(for: studio.id, message: "Offline")
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { machines.showsReconnectNotice(for: studio.id) }

    let message = UserMessage(text: "still there?")
    let send = Task { await model.send(message) }
    await client.sendAttempts.connectionWaits.wait()

    #expect(controller.activeItem == nil)
    #expect(controller.transcriptActivityOverride == nil)
    #expect(controller.transcriptProjectionInput.deliveries[message.id] == .sending)

    time.advance(by: 60)
    machines.markReady(for: studio.id)
    reconnect.finish()
    await send.value

    guard case let .assistant(turn)? = controller.activeItem else {
      Issue.record("The turn should show once the server takes the message")
      return
    }
    #expect(turn.turn.startedAt == time.now)
  }

  @Test(
    "A send that loses its machine gives up at its deadline as Not Delivered, and Try Again sends it once it's back")
  func disconnectedSendGivesUp() async throws {
    let (machines, _, _) = makeController(localServer: nil)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    let client = FakeSessionServerClient(sessionId: UUID())
    client.echoOnPrompt = false
    client.sendAttempts.failuresLeft = 1
    let (reconnection, reconnect) = AsyncStream.makeStream(of: Void.self)
    client.sendAttempts.reconnection = reconnection
    let controller = chat(on: machines, machineId: studio.id, client: client)
    let model = try #require(controller.model)
    model.sendGiveUpDelay = .milliseconds(50)
    let message = UserMessage(text: "still there?")

    await model.send(message)

    #expect(model.transcriptDeliveries[message.id]?.isFailed == true)
    reconnect.finish()
    await model.retryUnsentMessage(id: message.id)
    #expect(client.promptedMessageIds.contains(message.id.uuidString.lowercased()))
    #expect(model.transcriptDeliveries[message.id]?.isFailed != true)
  }

  @Test("A turn is timed from its send, or from when its machine came back if that was later")
  func turnIsTimedFromTheLaterOfSendAndReconnect() async {
    let (machines, _, _) = makeController(localServer: nil)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    let controller = chat(on: machines, machineId: studio.id)
    controller.pendingSendStartedAt = Date(timeIntervalSince1970: 0)

    machines.markFailed(for: studio.id, message: "Offline")
    machines.markReady(for: studio.id)
    let reconnectedAt = machines.connectedSince(studio.id)

    #expect(reconnectedAt != nil)
    #expect(controller.turnStartedAt == reconnectedAt)
    controller.pendingSendStartedAt = .distantFuture
    #expect(controller.turnStartedAt == .distantFuture)
  }

  @Test("A machine that answers again within a blip never counts as away")
  func briefMachineWaitStaysQuiet() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, connectionScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    signIn(machines, machines: [studio])
    machines.markReady(for: studio.id)

    machines.beginWaiting(for: studio.id, reason: .connecting)
    #expect(!machines.showsReconnectNotice(for: studio.id))
    machines.markReady(for: studio.id)
    #expect(!machines.showsReconnectNotice(for: studio.id))

    machines.beginWaiting(for: studio.id, reason: .connecting)
    await awaitObserved { clock.pendingCount == 1 }
    #expect(clock.requestedIntervals.last == .seconds(1))
    clock.advance()
    await awaitObserved { machines.showsReconnectNotice(for: studio.id) }
  }

  @Test("A failed machine reconnects as soon as its tunnel is back, not at its next scheduled retry")
  func tunnelReturnRecoversAFailedMachine() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let (machines, _, _) = makeController(localServer: nil, connectionScheduler: clock.scheduler)
    let studio = accountMachine("studio", name: "Mac Studio")
    let provider = signIn(machines, machines: [studio])
    await machines.prepareMachine(studio.id)
    #expect(machines.availability(for: studio.id) != .ready)
    #expect(machines.connection(for: studio.id).reconnector.isActive)

    provider.requestTransport.responsesByPath["/v1/info"] = """
      {"id":"studio","name":"Mac Studio","kind":"remote","version":"1.0.0",
       "platform":"darwin","bindHost":"127.0.0.1"}
      """
    machines.cloudMachineBecameReachable(deviceId: "studio")

    await awaitObserved { machines.availability(for: studio.id) == .ready }
    #expect(provider.requestTransport.requestCount(for: "/v1/info") >= 1)
  }
}

private final class TurnClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)

  var now: Date { lock.withLock { current } }

  func advance(by seconds: TimeInterval) {
    lock.withLock { current += seconds }
  }
}
