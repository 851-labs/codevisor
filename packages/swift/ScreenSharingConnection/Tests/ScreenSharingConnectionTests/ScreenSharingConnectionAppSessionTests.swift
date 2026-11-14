import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: app-owned sessions", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionAppSessionTests {
  private static let heartbeat = ScreenSharingConnectionDeadlines.heartbeatInterval
  private static let app = ServerScreenSharingApp(
    key: FakeMedia.address.endpointId, name: ConnectionHarness.appName)

  @Test("A host with app-owned sessions gets the app on capabilities and start, then only the session token")
  func presentsTheAppIdentity() async throws {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    await harness.beat()
    surface.detach()
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.clock.waitForSleep(ScreenSharingConnectionDeadlines.linger)
    await harness.stayLive(for: ScreenSharingConnectionDeadlines.linger)
    await awaitObserved { harness.host.stops.count == 1 }

    let start = try #require(harness.host.starts.first)
    let token = FakeHost.token(2)
    #expect(harness.host.requests(.capabilities).allSatisfy { $0.app == Self.app && $0.proof == nil })
    #expect(start.app == Self.app && start.intent == .attach && start.displayId == nil)
    #expect(harness.host.requests(.heartbeat).allSatisfy { $0.session == token && $0.app == nil })
    #expect(harness.host.stops[0].session == token && harness.host.stops[0].app == nil)
    #expect(harness.host.registeredPanes.isEmpty)
  }

  @Test("The saved display is asked for, and the display the host says it shares is the connection's display")
  func followsTheHostsDisplay() async {
    let harness = ConnectionHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    harness.connection.preferredDisplayId = FakeHost.second.id
    harness.show()
    await harness.goLive()

    #expect(harness.host.starts.map(\.displayId) == [FakeHost.second.id])
    #expect(harness.connection.display == FakeHost.second)
    #expect(harness.connection.displays == [FakeHost.display, FakeHost.second])
  }

  @Test("A host that stops advertising app-owned sessions is spoken to the old way on the next attempt")
  func readsAbilitiesOnEveryAttempt() async {
    let harness = ConnectionHarness()
    harness.show()
    let session = await harness.goLive()

    harness.host.abilities = []
    session.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    await harness.goLive()

    let operations = harness.host.requests.filter { [.start, .stop].contains($0.operation) }
    #expect(operations.map(\.operation) == [.start, .stop, .start])
    #expect(operations.map(\.app) == [Self.app, nil, nil])
    #expect(operations.map(\.session) == [nil, FakeHost.token(2), nil])
    #expect(harness.host.registeredPanes == [harness.legacyIdentity(harness.workspaces[0])])
  }

  @Test(
    "A failure the host does not classify gets one automatic reconnect; a second one before 30 s live is final",
    arguments: [false, true])
  func retriesAnUnclassifiedFailureOnce(stayedLive: Bool) async {
    let message = "The encoder stopped."
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerNext(.heartbeat, .reply(status: "failed", message: message))
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.reconnecting)
    await harness.goLive()

    if stayedLive { await harness.stayLive(for: ScreenSharingConnectionDeadlines.stableLive) }
    harness.host.answerNext(.heartbeat, .reply(status: "failed", message: message))
    harness.clock.advance(by: Self.heartbeat)
    if stayedLive {
      await harness.settle(.reconnecting)
      await harness.goLive()
    } else {
      await harness.settle(.failed(.unclassified(message: message)))
    }

    #expect(harness.host.starts.count == (stayedLive ? 3 : 2))
  }

  @Test("A reconnect whose start fails unclassified, right after an unclassified failure, shows the host's message")
  func stopsAfterOneRetryOfADeadCapture() async {
    let message = "The host Mac couldn't capture its screen."
    let harness = ConnectionHarness()
    harness.show()
    await harness.goLive()
    harness.host.answerNext(.heartbeat, .reply(status: "failed", message: message))
    harness.host.answerNext(.start, .reply(status: "failed", message: message))
    harness.clock.advance(by: Self.heartbeat)
    await harness.settle(.failed(.unclassified(message: message)))

    #expect(harness.host.starts.count == 2)
  }

  @Test("A stop that hangs doesn't delay the next start, is given up after 5 s, and its late reply changes nothing")
  func neverWaitsForAStop() async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    harness.host.hold(.stop)
    surface.setOnScreen(false)
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.clock.waitForSleep(ScreenSharingConnectionDeadlines.linger)
    await harness.stayLive(for: ScreenSharingConnectionDeadlines.linger)
    await harness.settle(.off)
    await awaitObserved { harness.host.stops.count == 1 }

    surface.setOnScreen(true)
    let second = await harness.goLive()
    await harness.elapse(ScreenSharingConnectionDeadlines.stopRequest)
    harness.host.release(.stop)
    await harness.beat()

    #expect(harness.connection.state == .live && !second.isClosed)
    #expect(harness.host.starts.count == 2 && harness.host.stops.count == 1)
    #expect(harness.host.stops[0].viewerId == harness.host.starts[0].viewerId)
  }

  @Test("A start still in flight when the connection turns off is stopped, and stopped again if it is granted late")
  func stopsAStartThatIsGrantedLate() async {
    let harness = ConnectionHarness()
    harness.host.hold(.start)
    let surface = harness.show()
    await awaitObserved { harness.host.starts.count == 1 }
    surface.setOnScreen(false)
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.settle(.off)
    await awaitObserved { harness.host.stops.count == 1 }

    harness.host.release(.start)
    await awaitObserved { harness.host.stops.count == 2 }

    let attempt = harness.host.starts[0].viewerId
    #expect(harness.host.stops.map(\.viewerId) == [attempt, attempt])
    #expect(harness.host.stops.map(\.session) == [nil, FakeHost.token(2)], "no token until the start is answered")
    #expect(harness.connection.state == .off && harness.media.sessions.isEmpty, "the late grant opened nothing")
  }

  @Test("A server client that was replaced is the one the next attempt talks to")
  func asksForTheChannelOnEveryAttempt() async {
    let harness = ConnectionHarness()
    let original = harness.host
    harness.show()
    let session = await harness.goLive()

    let replacement = FakeHost()
    harness.host = replacement
    session.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    await harness.goLive()

    #expect(original.starts.count == 1 && replacement.starts.count == 1)
  }
}
