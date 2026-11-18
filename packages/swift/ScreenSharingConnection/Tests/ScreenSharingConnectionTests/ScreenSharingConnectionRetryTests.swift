import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: retries", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionRetryTests {
  @Test("Reconnecting tries five times, after 0, 1, 2, 4 and 8 s, then fails as kept dropping")
  func retriesOnTheScheduleThenFails() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.media.connectFails = true

    await harness.useUpTheTries(failingAt: .start)
    await harness.settle(.failed(.keptDropping))

    #expect(harness.host.starts.count == 6)
  }

  @Test("Automatic tries never ask for a fresh link to the machine; the user's Retry does")
  func onlyTheUserAsksForAFreshLink() async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    await harness.useUpTheTries(failingAt: .capabilities)
    await harness.settle(.failed(.cantReach))
    #expect(harness.userAsks == 0)

    harness.host.answerEvery(.capabilities, nil)
    surface.retry()

    #expect(harness.userAsks == 1)
    await harness.goLive()
  }

  @Test("Tries used up without reaching the machine fail as can't reach, and the machine coming back reconnects")
  func failsAsUnreachableWhenTheMachineIsGone() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))

    await harness.useUpTheTries(failingAt: .capabilities)
    await harness.settle(.failed(.cantReach))

    harness.host.answerEvery(.capabilities, nil)
    harness.manager.machineCameOnline(ConnectionHarness.machineId)
    await harness.goLive()
    #expect(harness.host.starts.map(\.intent) == [.attach, .attach])
  }

  @Test("The machine coming back during the last tries reconnects with one more try once they run out")
  func machineBackDuringTheTries() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))

    await harness.useUpTheTries(failingAt: .capabilities) { index in
      guard index == ScreenSharingRetryPolicy.waits.count - 2 else { return }
      harness.machineReady = true
      harness.manager.machineCameOnline(ConnectionHarness.machineId)
      harness.host.answerEvery(.capabilities, nil)
      harness.host.answerNext(.capabilities, .failure(FakeHost.unreachable), .failure(FakeHost.unreachable))
    }
    await harness.goLive()

    #expect(harness.host.requests(.capabilities).count == ScreenSharingRetryPolicy.waits.count + 2)
    #expect(harness.host.starts.map(\.intent) == [.attach, .attach])
  }

  @Test(
    "A ready machine that still can't be reached gets one more try at once, not a loop, and coming back still reconnects"
  )
  func oneMoreTryWhileReady() async {
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    harness.machineReady = true

    await harness.useUpTheTries(failingAt: .capabilities)
    await awaitObserved { harness.host.requests(.capabilities).count == ScreenSharingRetryPolicy.waits.count + 2 }
    await harness.settle(.failed(.cantReach))
    await harness.clock.waitForSleep(ScreenSharingRetryPolicy.quietWaits[0])
    #expect(harness.host.requests(.capabilities).count == ScreenSharingRetryPolicy.waits.count + 2)

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
