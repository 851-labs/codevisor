import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: deadlines", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionDeadlineTests {
  private static let tick = Duration.milliseconds(1)

  private func reachTheHint(_ harness: ConnectionHarness) async {
    await harness.clock.waitForSleep(.seconds(4))
    harness.clock.advance(by: .seconds(4) - Self.tick)
    #expect(!harness.connection.isTakingLong)
    harness.clock.advance(by: Self.tick)
    await awaitObserved { harness.connection.isTakingLong }
    await harness.clock.waitForSleep(.seconds(6))
  }

  @Test("A connect with no picture says it's taking long at 4 s, fails at 10 s and is not retried")
  func failsWithoutAFirstFrame() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.startedSession()

    await reachTheHint(harness)
    harness.clock.advance(by: .seconds(6) - Self.tick)
    #expect(harness.connection.state == .connecting(.waitingForVideo))
    harness.clock.advance(by: Self.tick)
    await harness.settle(.failed(.noVideo))
    await awaitObserved { harness.host.requests(.stop).count == 1 }

    #expect(session.isClosed && !harness.connection.isTakingLong)
    #expect(harness.host.starts.count == 1)
    await harness.noTimersLeft()
  }

  enum StuckStep: CaseIterable, Sendable { case reachingTheMachine, askingTheHost, settingUpVideo }

  @Test("A connect stuck before video fails at 10 s with the step it was stuck on", arguments: StuckStep.allCases)
  func failsWithTheStuckStep(_ step: StuckStep) async {
    let harness = ConnectionHarness()
    switch step {
    case .reachingTheMachine: harness.host.hold(.capabilities)
    case .askingTheHost: harness.host.hold(.start)
    case .settingUpVideo: harness.media.handshakeHangs = true
    }
    harness.show()
    switch step {
    case .reachingTheMachine: await awaitObserved { harness.host.requests(.capabilities).count == 1 }
    case .askingTheHost: await awaitObserved { harness.host.starts.count == 1 }
    case .settingUpVideo: await awaitObserved { harness.media.sessions.first?.tokens.count == 1 }
    }

    await reachTheHint(harness)
    harness.clock.advance(by: .seconds(6))
    await harness.settle(.failed(step == .settingUpVideo ? .networkBlocked : .cantReach))

    #expect(harness.media.sessions.allSatisfy { $0.isClosed })
  }

  @Test("While the app's link to the machine is reconnecting, the first frame gets 5 s more")
  func waitsLongerWhileTheLinkReconnects() async {
    let harness = ConnectionHarness()
    harness.host.isReconnecting = true
    harness.show()
    _ = await harness.startedSession()

    await reachTheHint(harness)
    harness.clock.advance(by: .seconds(6))
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5) - Self.tick)
    #expect(harness.connection.state == .connecting(.waitingForVideo))
    harness.clock.advance(by: Self.tick)
    await harness.settle(.failed(.noVideo))
  }

  @Test("While the host says it is restarting capture the deadline is paused, then the first frame gets a fresh 10 s")
  func pausesWhileTheHostRestartsCapture() async {
    let notice = "Capture stalled, restarting…"
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "connecting", message: notice))
    harness.host.answerEvery(.heartbeat, .reply(status: "connecting", message: notice))
    harness.show()
    let session = await harness.startedSession()
    #expect(harness.connection.hostNotice == notice)

    await reachTheHint(harness)
    await harness.beat(after: .seconds(4))
    await harness.tick(after: .seconds(2))
    #expect(harness.connection.state == .connecting(.waitingForVideo) && !session.isClosed, "paused at 10 s")

    harness.host.answerEvery(.heartbeat, nil)
    await harness.beat(after: .seconds(6))
    harness.clock.advance(by: .seconds(2))
    await harness.clock.waitForSleep(.seconds(10))
    #expect(harness.connection.hostNotice == nil)
    harness.clock.advance(by: .seconds(10) - Self.tick)
    #expect(harness.connection.state == .connecting(.waitingForVideo))
    harness.clock.advance(by: Self.tick)
    await harness.settle(.failed(.noVideo))
  }

  enum Interrupted: CaseIterable, Sendable { case capabilities, startOnAnOldHost }

  @Test(
    "A request the relay interrupts, or the gateway times out, is sent again inside the connect and still goes live",
    arguments: Interrupted.allCases, [false, true])
  func resendsAnInterruptedRequest(_ interrupted: Interrupted, gatewayTimedOut: Bool) async {
    let harness = ConnectionHarness(host: interrupted == .capabilities ? FakeHost() : .old())
    let operation: FakeHost.Operation = interrupted == .capabilities ? .capabilities : .start
    harness.host.answerNext(operation, .failure(gatewayTimedOut ? FakeHost.gatewayTimedOut : FakeHost.interrupted))
    harness.show()

    await harness.elapse(.milliseconds(500))
    await harness.goLive()

    #expect(harness.host.requests(operation).count == 2)
    #expect(harness.host.requests(.stop).isEmpty, "the connection never failed in between")
  }
}
