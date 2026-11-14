import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: state transitions", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionTransitionTests {
  private static let heartbeat = ScreenSharingConnectionDeadlines.heartbeatInterval

  @Test("Attaching hidden sends nothing; the first visible surface starts connecting")
  func startsOnTheFirstVisibleSurface() async {
    let harness = ConnectionHarness()
    let surface = harness.connection.attach(.tab)
    surface.size = ScreenSharingSurfaceSize(width: 1280, height: 800, scale: 2)
    #expect(harness.connection.state == .off)

    surface.setOnScreen(true)
    #expect(harness.connection.state == .connecting(.reachingHost))
    _ = await harness.startedSession()

    #expect(harness.host.requests.map(\.operation) == [.capabilities, .start])
    #expect(harness.connection.state == .connecting(.waitingForVideo))
  }

  @Test("The first decoded frame makes the connection live, with no view drawing it")
  func goesLiveOnTheFirstDecodedFrame() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()

    #expect(harness.connection.session === session)
    #expect(session.frames.take() != nil, "the frame is still there for a view to draw")
  }

  struct Refusal: Sendable, CustomTestStringConvertible {
    var operation: FakeHost.Operation
    var status: String
    var reason: String?
    var holderName: String?
    var message: String?
    var expected: ScreenSharingFailureReason
    var testDescription: String { reason ?? status }
  }

  nonisolated static let refusals = [
    Refusal(
      operation: .capabilities, status: "permission-required", reason: "permission-missing",
      expected: .permissionMissing),
    Refusal(operation: .capabilities, status: "unavailable", reason: "update-needed", expected: .updateNeeded),
    Refusal(operation: .start, status: "unavailable", reason: "no-display", expected: .noDisplay),
    Refusal(operation: .start, status: "failed", reason: "display-asleep", expected: .displayAsleep),
    Refusal(
      operation: .start, status: "busy", reason: "in-use", holderName: "Alexandru's iPhone",
      expected: .inUse(by: "Alexandru's iPhone")),
    Refusal(
      operation: .start, status: "failed", message: "The host Mac couldn't start capturing its screen. Try again.",
      expected: .unclassified(message: "The host Mac couldn't start capturing its screen. Try again.")),
  ]

  @Test("A host that refuses the first connect fails it with the host's reason and is not retried", arguments: refusals)
  func failsWhenTheHostRefuses(_ refusal: Refusal) async {
    let harness = ConnectionHarness()
    harness.host.answerNext(
      refusal.operation,
      .reply(
        status: refusal.status, message: refusal.message, reason: refusal.reason, holderName: refusal.holderName))
    harness.show()
    await harness.settle(.failed(refusal.expected))

    #expect(harness.host.starts.count == (refusal.operation == .start ? 1 : 0))
    await harness.noTimersLeft()
  }

  @Test("A VNC machine viewed from an app that brings no VNC transport fails as unsupported here, with no start")
  func failsForAVNCMachineWithoutATransport() async {
    let host = FakeHost.old()
    host.provider = "vnc"
    let harness = ConnectionHarness(host: host)
    harness.show()
    await harness.settle(.failed(.unsupportedOnThisDevice))

    #expect(host.starts.isEmpty && host.registeredPanes.isEmpty)
    await harness.noTimersLeft()
  }

  enum Loss: CaseIterable, Sendable { case videoDropped, hostForgotTheSession, thisDeviceWoke }

  @Test("A lost stream reconnects by itself and goes live again on a decoded frame", arguments: Loss.allCases)
  func reconnectsAfterALoss(_ loss: Loss) async {
    let harness = ConnectionHarness()
    harness.open(.tab)
    let first = await harness.goLive()

    switch loss {
    case .videoDropped:
      first.host.report(connection: "failed")
    case .hostForgotTheSession:
      harness.host.answerNext(.heartbeat, .reply(status: "stopped", message: "Screen sharing ended on the host Mac."))
      harness.clock.advance(by: Self.heartbeat)
    case .thisDeviceWoke:
      harness.manager.systemWoke()
    }
    await harness.settle(.reconnecting)
    let second = await harness.goLive()

    #expect(first.isClosed && !second.isClosed)
    #expect(harness.host.starts.map(\.intent) == [.open, .attach], "a reconnect never takes over")
    #expect(harness.host.requests(.stop).isEmpty)
  }

  @Test("One failed heartbeat leaves a healthy stream alone; 25 s of failed heartbeats reconnects")
  func toleratesFailedHeartbeatsFor25Seconds() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()

    harness.host.answerNext(.heartbeat, .failure(FakeHost.unreachable))
    await harness.beat()
    await harness.beat()
    #expect(harness.connection.state == .live && !session.isClosed)

    harness.host.answerEvery(.heartbeat, .failure(FakeHost.unreachable))
    for _ in 1...3 { await harness.beat() }
    #expect(harness.connection.state == .live, "24 s without an answer is still inside the limit")
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.reconnecting)

    #expect(session.isClosed)
  }

  @Test("A heartbeat that never returns counts as failing and does not hold back the next ones")
  func countsAHungHeartbeatAsFailing() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.hold(.heartbeat)

    for _ in 1...3 { await harness.tick() }
    await awaitObserved { harness.host.requests(.heartbeat).count == 3 }
    #expect(harness.connection.state == .live)
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.reconnecting)
  }

  @Test("If the host can't be asked why the video ended, nothing is started; the next try asks again")
  func neverStartsWithoutKnowingWhyItEnded() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()
    harness.host.answerNext(.heartbeat, .failure(FakeHost.unreachable))
    harness.host.answerEvery(.heartbeat, .reply(status: "failed", reason: "stopped-on-host"))

    session.host.report(connection: "failed")
    await harness.clock.waitForSleep(.seconds(1))
    #expect(harness.connection.state == .reconnecting)
    #expect(harness.host.requests(.capabilities).count == 1 && harness.host.starts.count == 1)
    harness.clock.advance(by: .seconds(1))
    await harness.settle(.failed(.stoppedOnHost))

    #expect(harness.host.requests(.heartbeat).count == 2 && harness.host.starts.count == 1)
  }

  struct HostEnd: Sendable, CustomTestStringConvertible {
    var reason: String
    var holderName: String?
    var expected: ScreenSharingFailureReason
    var testDescription: String { reason }
  }

  nonisolated static let hostEnds = [
    HostEnd(reason: "taken-over", holderName: "Alexandru's iPhone", expected: .takenOver(by: "Alexandru's iPhone")),
    HostEnd(reason: "stopped-on-host", expected: .stoppedOnHost),
    HostEnd(reason: "display-asleep", expected: .displayAsleep),
    HostEnd(reason: "session-switched", expected: .sessionSwitched),
    HostEnd(reason: "no-display", expected: .noDisplay),
  ]

  @Test("A session the host ends on purpose fails with its reason and is never restarted", arguments: hostEnds)
  func failsWhenTheHostEndsTheSession(_ end: HostEnd) async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()
    harness.host.answerEvery(.heartbeat, .reply(status: "failed", reason: end.reason, holderName: end.holderName))
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.failed(end.expected))

    #expect(session.isClosed && harness.host.starts.count == 1)
    await harness.noTimersLeft()
  }

  @Test("When the video drops because sharing was stopped on the host, the connection fails without restarting")
  func asksTheHostWhyTheVideoEnded() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()
    harness.host.answerEvery(.heartbeat, .reply(status: "failed", reason: "stopped-on-host"))
    session.host.report(connection: "failed")
    await harness.settle(.failed(.stoppedOnHost))

    #expect(harness.host.starts.count == 1)
  }

  @Test("After sharing was stopped on the host, coming back on screen is refused the same way and only Connect opens")
  func staysStoppedUntilTheUserConnects() async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    harness.host.answerEvery(.heartbeat, .reply(status: "failed", reason: "stopped-on-host"))
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.failed(.stoppedOnHost))

    harness.host.answerEvery(.heartbeat, nil)
    harness.host.answerNext(.start, .reply(status: "failed", reason: "stopped-on-host"))
    surface.setOnScreen(false)
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.settle(.off)
    surface.setOnScreen(true)
    await harness.settle(.failed(.stoppedOnHost))

    surface.retry()
    await harness.goLive()
    #expect(harness.host.starts.map(\.intent) == [.attach, .attach, .open])
  }

  @Test("A reconnect refused because another device opened the desktop fails with that device's name")
  func failsAReconnectTheHostRefuses() async {
    let harness = ConnectionHarness()
    harness.open(.tab)
    let session = await harness.goLive()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    session.host.report(connection: "failed")
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    #expect(harness.host.starts.map(\.intent) == [.open, .attach])
  }

  enum UserAction: CaseIterable, Sendable { case retry, viewHere }

  @Test("Retry and View here connect again from Failed and ask to take over", arguments: UserAction.allCases)
  func connectsAgainWhenTheUserAsks(_ action: UserAction) async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    let preview = harness.show(.preview)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    switch action {
    case .retry: preview.retry()
    case .viewHere: preview.viewHere()
    }
    #expect(harness.connection.state == .connecting(.reachingHost))
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
  }

  @Test("A machine that comes back online reconnects a connection that couldn't reach it")
  func reconnectsWhenTheMachineComesBack() async {
    let harness = ConnectionHarness()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    harness.show()
    await harness.settle(.failed(.cantReach))

    harness.host.answerEvery(.capabilities, nil)
    harness.manager.machineCameOnline(ConnectionHarness.machineId)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("A machine that comes back online does not restart a connection that failed for another reason")
  func staysFailedWhenTheMachineComesBackAfterARefusal() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.capabilities, .reply(status: "permission-required", reason: "permission-missing"))
    harness.show()
    await harness.settle(.failed(.permissionMissing))

    harness.manager.machineCameOnline(ConnectionHarness.machineId)

    #expect(harness.connection.state == .failed(.permissionMissing))
    #expect(harness.host.requests.count == 1 && harness.clock.pendingCount == 0)
  }
}
