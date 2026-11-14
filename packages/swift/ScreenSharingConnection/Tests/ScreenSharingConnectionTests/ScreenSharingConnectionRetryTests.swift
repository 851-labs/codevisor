import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: retries", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionRetryTests {
  private func useUpTheTries(_ harness: ConnectionHarness, failingAt operation: FakeHost.Operation) async {
    let before = harness.host.requests(operation).count
    harness.host.hold(operation)
    harness.media.sessions.last?.host.report(connection: "failed")
    for (index, wait) in ScreenSharingRetryPolicy.waits.dropFirst().enumerated() {
      await awaitObserved { harness.host.requests(operation).count == before + index + 1 }
      await harness.clock.waitForSleep(ScreenSharingConnectionDeadlines.stillConnectingHint)
      let earlierWaits = harness.clock.requestCount(wait)
      harness.host.release(operation)
      harness.host.hold(operation)
      await harness.clock.waitForSleep(wait, count: earlierWaits + 1)
      harness.clock.advance(by: wait - .milliseconds(1))
      #expect(harness.host.requests(operation).count == before + index + 1)
      #expect(harness.connection.state == .reconnecting)
      harness.clock.advance(by: .milliseconds(1))
    }
    await awaitObserved { harness.host.requests(operation).count == before + ScreenSharingRetryPolicy.waits.count }
    harness.host.release(operation)
  }

  @Test("Reconnecting tries five times, after 0, 1, 2, 4 and 8 s, then fails as kept dropping")
  func retriesOnTheScheduleThenFails() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.media.connectFails = true

    await useUpTheTries(harness, failingAt: .start)
    await harness.settle(.failed(.keptDropping))

    #expect(harness.host.starts.count == 6)
    await harness.noTimersLeft()
  }

  @Test("Tries used up without reaching the machine fail as can't reach, and the machine coming back reconnects")
  func failsAsUnreachableWhenTheMachineIsGone() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))

    await useUpTheTries(harness, failingAt: .capabilities)
    await harness.settle(.failed(.cantReach))

    harness.host.answerEvery(.capabilities, nil)
    harness.manager.machineCameOnline(ConnectionHarness.machineId)
    await harness.goLive()
    #expect(harness.host.starts.map(\.intent) == [.attach, .attach])
  }

  @Test("A link that shows a picture for 2 s and drops, again and again, fails as kept dropping after five tries")
  func givesUpOnALinkThatKeepsDropping() async {
    let harness = ConnectionHarness()
    harness.show()
    var session = await harness.goLive()

    for wait in ScreenSharingRetryPolicy.waits {
      harness.clock.advance(by: .seconds(2))
      session.host.report(connection: "failed")
      await harness.settle(.reconnecting)
      if wait > .zero { await harness.elapseRetryWait(wait) }
      session = await harness.goLive()
    }
    harness.clock.advance(by: .seconds(2))
    session.host.report(connection: "failed")
    await harness.settle(.failed(.keptDropping))

    #expect(harness.host.starts.count == 6)
  }

  @Test("After staying live for 30 s the earlier tries are forgiven", arguments: [false, true])
  func forgivesTriesAfterStayingLive(stayedLive: Bool) async {
    let harness = ConnectionHarness()
    harness.show()
    let first = await harness.goLive()
    first.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    let second = await harness.goLive()

    let stable = ScreenSharingConnectionDeadlines.stableLive
    await harness.stayLive(for: stayedLive ? stable : stable - .milliseconds(1))
    #expect(harness.connection.state == .live)
    harness.media.connectFails = true
    second.host.report(connection: "failed")
    await harness.clock.waitForSleep(.seconds(1))

    #expect(
      harness.host.starts.count == (stayedLive ? 3 : 2),
      "a forgiven connection tries at once; otherwise the second try waits its 1 s first")
  }
}
