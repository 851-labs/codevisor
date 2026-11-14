import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: restart and display switching", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionRestartTests {
  enum Moment: CaseIterable, Sendable { case live, reconnecting }

  private func reach(_ moment: Moment, on harness: ConnectionHarness) async {
    let session = await harness.goLive()
    guard moment == .reconnecting else { return }

    harness.media.connectFails = true
    session.host.report(connection: "failed")
    await awaitObserved { harness.host.starts.count == 2 }
    await harness.clock.waitForSleep(.seconds(1))
    harness.media.connectFails = false
  }

  @Test(
    "Restart stops the current attempt and starts a new one as an attach, with surfaces and timers untouched",
    arguments: Moment.allCases)
  func restartsAsAnAttach(during moment: Moment) async {
    let harness = ConnectionHarness()
    let tab = harness.open(.tab)
    harness.show(.preview)
    await reach(moment, on: harness)
    let before = harness.host.starts

    harness.connection.restart()
    #expect(harness.connection.state == .reconnecting)
    let live = await harness.goLive()

    #expect(harness.host.stops.map(\.viewerId) == [before.last?.viewerId])
    #expect(harness.host.starts.count == before.count + 1 && harness.host.starts.last?.intent == .attach)
    #expect(harness.connection.surfaces.map(\.isOnScreen) == [true, true] && tab.isAttached)
    #expect(harness.media.sessions.filter { !$0.isClosed }.map { $0 === live } == [true])
    #expect(harness.clock.requestCount(ScreenSharingConnectionDeadlines.unseenDebounce) == 0)
  }

  @Test("Restart from Failed behaves like Retry and asks to take over")
  func restartsFromFailedAsAnOpen() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    harness.show(.preview)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    harness.connection.restart()
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
  }

  @Test("Restart and a display switch with nothing on screen send nothing; the display is used at the next start")
  func doesNothingWhileOff() async {
    let harness = ConnectionHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    let surface = harness.connection.attach(.tab)

    harness.connection.restart()
    harness.connection.switchDisplay(to: FakeHost.second.id)
    #expect(harness.connection.state == .off && harness.host.requests.isEmpty)

    surface.setOnScreen(true)
    await harness.goLive()
    #expect(harness.host.starts.map(\.displayId) == [FakeHost.second.id])
    #expect(harness.connection.display == FakeHost.second)
  }

  @Test(
    "Switching display stops the current attempt and starts one for the new display as an attach",
    arguments: Moment.allCases)
  func switchesDisplayByRestarting(during moment: Moment) async {
    let harness = ConnectionHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    harness.open(.window)
    await reach(moment, on: harness)
    let before = harness.host.starts

    harness.connection.switchDisplay(to: FakeHost.second.id)
    await harness.goLive()

    let start = harness.host.starts.last
    #expect(harness.host.stops.map(\.viewerId) == [before.last?.viewerId])
    #expect(harness.host.starts.count == before.count + 1)
    #expect(start?.displayId == FakeHost.second.id && start?.intent == .attach)
    #expect(harness.connection.display == FakeHost.second && harness.connection.surfaces.count == 1)
  }

  @Test("Switching to the display that is already shared changes nothing")
  func keepsTheSessionForTheSameDisplay() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()
    let sent = harness.host.requests.count

    harness.connection.switchDisplay(to: FakeHost.display.id)

    #expect(harness.connection.state == .live && !session.isClosed && harness.host.requests.count == sent)
    #expect(harness.connection.preferredDisplayId == FakeHost.display.id)
  }
}
