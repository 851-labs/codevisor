import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: recovering by itself on a surface that stays on screen", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionRecoveryTests {
  private static let quietWaits = ScreenSharingRetryPolicy.quietWaits
  private static let debounce = ScreenSharingConnectionDeadlines.unseenDebounce

  private func keepDropping(_ harness: ConnectionHarness) async {
    harness.show(.preview)
    await harness.goLive()
    harness.media.connectFails = true
    await harness.useUpTheTries(failingAt: .start)
    await harness.settle(.failed(.keptDropping))
  }

  @Test("A preview left on screen through an outage longer than the five tries goes live again by itself")
  func recoversAfterAnOutageLongerThanTheTries() async {
    let harness = ConnectionHarness()
    await keepDropping(harness)
    harness.media.connectFails = false

    await harness.elapse(Self.quietWaits[0])
    let session = await harness.startedSession()
    #expect(harness.connection.state == .failed(.keptDropping), "the reason stays up until there is a picture")
    session.host.deliverFrame(identity: 1)
    await harness.settle(.live)

    #expect(harness.host.starts.allSatisfy { $0.intent == .attach }, "a quiet try never takes over")
  }

  @Test("While the host stays away the quiet tries slow down to one every five minutes, and stop once nothing is shown")
  func slowsDownAndStopsWhenHidden() async {
    let harness = ConnectionHarness()
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    let surface = harness.show(.preview)
    await harness.settle(.failed(.cantReach))

    let slowest = Self.quietWaits[Self.quietWaits.count - 1]
    let waits = Self.quietWaits + [slowest, slowest]
    for (index, wait) in waits.enumerated() {
      await harness.clock.waitForSleep(wait, count: waits[...index].filter { $0 == wait }.count)
      harness.clock.advance(by: wait - .milliseconds(1))
      #expect(harness.host.requests(.capabilities).count == index + 1)
      harness.clock.advance(by: .milliseconds(1))
      await awaitObserved { harness.host.requests(.capabilities).count == index + 2 }
      #expect(harness.connection.state == .failed(.cantReach))
    }
    await harness.clock.waitForSleep(slowest, count: waits.filter { $0 == slowest }.count + 1)

    surface.setOnScreen(false)
    await harness.elapse(Self.debounce)
    await harness.settle(.off)
    await harness.noTimersLeft()
    #expect(harness.host.requests(.capabilities).count == waits.count + 1)
  }

  @Test("A quiet try the host refuses shows the host's reason and is the last one")
  func stopsAtTheHostsAnswer() async {
    let harness = ConnectionHarness()
    await keepDropping(harness)
    harness.media.connectFails = false
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))

    await harness.elapse(Self.quietWaits[0])
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    await harness.noTimersLeft()
    #expect(harness.host.starts.allSatisfy { $0.intent == .attach })
  }

  @Test(
    "A preview hidden while live that loses its host turns off when the tries run out, and showing it connects afresh")
  func turnsOffWhenTheTriesRunOutWithNothingOnScreen() async {
    let harness = ConnectionHarness()
    let surface = harness.show(.preview)
    await harness.goLive()
    surface.setOnScreen(false)
    await harness.elapse(Self.debounce)
    await harness.clock.waitForSleep(ScreenSharingConnectionDeadlines.linger)

    harness.media.connectFails = true
    await harness.useUpTheTries(failingAt: .start)
    await harness.settle(.off)

    await harness.noTimersLeft()
    #expect(harness.media.sessions.count == 1, "nothing went live while hidden")
    harness.media.connectFails = false
    surface.setOnScreen(true)
    #expect(harness.connection.state == .connecting(.reachingHost))
    await harness.goLive()
    #expect(harness.host.starts.allSatisfy { $0.intent == .attach })
  }

  enum Nudge: CaseIterable, Sendable { case thisDeviceWoke, machineCameOnline }

  @Test(
    "After the tries ran out, this device waking or the machine coming back tries again at once",
    arguments: Nudge.allCases)
  func triesAgainAtOnceWhenNudged(_ nudge: Nudge) async {
    let harness = ConnectionHarness()
    await keepDropping(harness)
    harness.media.connectFails = false

    switch nudge {
    case .thisDeviceWoke: harness.manager.systemWoke()
    case .machineCameOnline: harness.manager.machineCameOnline(ConnectionHarness.machineId)
    }

    #expect(harness.connection.state == .connecting(.reachingHost))
    await harness.goLive()
    #expect(harness.host.starts.allSatisfy { $0.intent == .attach })
  }

  @Test("Waking in the middle of the tries makes the next try at once instead of waiting out its delay")
  func wakingSkipsTheWaitBetweenTries() async {
    let harness = ConnectionHarness()
    harness.show(.preview)
    let first = await harness.goLive()
    harness.media.connectFails = true
    first.host.report(connection: "failed")
    await harness.clock.waitForSleep(ScreenSharingRetryPolicy.waits[1])
    harness.media.connectFails = false

    harness.manager.systemWoke()

    await harness.goLive()
    #expect(harness.host.starts.count == 3)
  }

  enum Cancelled: CaseIterable, Sendable {
    case task, request

    var error: any Error {
      switch self {
      case .task: CancellationError()
      case .request: URLError(.cancelled)
      }
    }
  }

  @Test(
    "A request cancelled underneath a try counts as a failed try, so the next one still runs",
    arguments: Cancelled.allCases)
  func countsARequestCancelledUnderneathAsAFailedTry(_ cancelled: Cancelled) async {
    let harness = ConnectionHarness()
    harness.show(.preview)
    let first = await harness.goLive()
    harness.host.answerNext(.capabilities, .failure(cancelled.error))

    first.host.report(connection: "failed")
    await harness.elapse(ScreenSharingRetryPolicy.waits[1])

    await harness.goLive()
    #expect(harness.host.requests(.capabilities).count == 3)
  }
}
