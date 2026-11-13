import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: app-owned sessions", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionAppSessionTests {
  private static let app = ScreenSharingHostRequest.App(
    key: FakeMedia.address.endpointId, name: ConnectionHarness.appName)

  @Test("A host with app-owned sessions gets the app's key and name on start, heartbeat and stop, and no pane")
  func presentsTheAppIdentity() async throws {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    await harness.stayLive()
    surface.detach()
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.elapse(ScreenSharingConnectionDeadlines.linger)
    await awaitObserved { harness.host.requests(.stop).count == 1 }

    let start = try #require(harness.host.starts.first)
    #expect(harness.host.requests(.capabilities).allSatisfy { $0.app == nil })
    #expect(start.app == Self.app && start.intent == .attach && start.base.displayId == nil)
    #expect(harness.host.requests(.heartbeat).allSatisfy { $0.app == Self.app && $0.intent == nil })
    #expect(harness.host.requests(.stop)[0].app == Self.app)
    #expect(harness.host.registeredPanes.isEmpty)
  }

  @Test("The saved display is asked for, and the display the host says it shares is the connection's display")
  func followsTheHostsDisplay() async {
    let harness = ConnectionHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    harness.connection.preferredDisplayId = FakeHost.second.id
    _ = harness.show()
    await harness.goLive()

    #expect(harness.host.starts.map(\.base.displayId) == [FakeHost.second.id])
    #expect(harness.connection.display == FakeHost.second)
    #expect(harness.connection.displays == [FakeHost.display, FakeHost.second])
  }

  @Test("A host that stops advertising app-owned sessions is spoken to the old way on the next attempt")
  func readsAbilitiesOnEveryAttempt() async {
    let harness = ConnectionHarness()
    _ = harness.show()
    let session = await harness.goLive()

    harness.host.abilities = []
    session.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    await harness.goLive()

    let operations = harness.host.requests.filter { [.start, .stop].contains($0.base.operation) }
    #expect(operations.map(\.base.operation) == [.start, .stop, .start])
    #expect(operations.map(\.app) == [Self.app, Self.app, nil])
    #expect(harness.host.registeredPanes == [harness.legacyIdentity(harness.workspaces[0])])
  }

  @Test("A failure the host does not classify while live is treated as a drop and reconnects")
  func reconnectsAfterAnUnclassifiedFailure() async {
    let harness = ConnectionHarness()
    _ = harness.show()
    await harness.goLive()
    harness.host.answerNext(.heartbeat, .reply(status: "failed", message: "The encoder stopped."))
    harness.clock.advance(by: ScreenSharingConnectionDeadlines.heartbeatInterval)
    await harness.settle(.reconnecting)
    await harness.goLive()

    #expect(harness.host.starts.count == 2)
  }

  @Test("A stop still in flight holds back the next start, and each stop names the attempt it ends")
  func sendsNoStartWhileAStopIsInFlight() async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    await harness.goLive()
    harness.host.hold(.stop)
    surface.setOnScreen(false)
    await harness.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await harness.elapse(ScreenSharingConnectionDeadlines.linger)
    await awaitObserved { harness.host.requests(.stop).count == 1 }

    surface.setOnScreen(true)
    await harness.clock.waitForSleep(.seconds(4))
    harness.clock.advance(by: .seconds(4))
    await harness.elapse(.seconds(6))
    await harness.settle(.failed(.cantReach))
    #expect(
      harness.host.requests(.capabilities).count == 1 && harness.host.starts.count == 1,
      "a whole connect deadline passed with nothing sent")

    harness.host.release(.stop)
    surface.retry()
    await harness.goLive()

    let sent = harness.host.requests.map(\.base).filter { $0.operation != .heartbeat }
    #expect(sent.map(\.operation) == [.capabilities, .start, .stop, .capabilities, .start])
    #expect(sent[2].viewerId == sent[1].viewerId && sent[4].viewerId != sent[1].viewerId)
  }
}
