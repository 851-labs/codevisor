import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: switching display in a live session", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionDisplaySwitchTests {
  private typealias Switch = ScreenSharingDisplaySwitch

  nonisolated private static let first = FakeHost.display
  nonisolated private static let second = FakeHost.second
  nonisolated private static let third = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000003", name: "Projector", width: 1280, height: 720)

  private func liveHarness(host: FakeHost = FakeHost()) async -> (ConnectionHarness, LoopbackSession) {
    host.displays = [Self.first, Self.second, Self.third]
    let harness = ConnectionHarness(host: host)
    harness.show()
    let session = await harness.goLive()
    return (harness, session)
  }

  private func heartbeats(_ harness: ConnectionHarness, answered count: Int) async {
    await awaitObserved { harness.host.completed(.heartbeat) == count }
  }

  private func askedDisplays(_ harness: ConnectionHarness) -> [String?] {
    harness.host.requests(.heartbeat).map(\.displayId)
  }

  @Test("Against a host that can switch, picking a display sends one heartbeat with it and the session stays live")
  func switchesInSession() async {
    let (harness, session) = await liveHarness()
    let connection = harness.connection

    connection.switchDisplay(to: Self.second.id)
    #expect(connection.state == .live && connection.preferredDisplayId == nil)
    #expect(connection.displaySwitch == Switch(displayId: Self.second.id, name: Self.second.name, phase: .switching))
    await awaitObserved { connection.displaySwitch?.phase == .confirmed }

    #expect(connection.display == Self.second && connection.preferredDisplayId == Self.second.id)
    #expect(connection.state == .live && !session.isClosed)
    #expect(askedDisplays(harness) == [Self.second.id] && harness.host.requests(.heartbeat)[0].session != nil)
    #expect(harness.host.starts.count == 1 && harness.host.stops.isEmpty)

    connection.switchDisplay(to: Self.second.id)
    await harness.beat()
    #expect(askedDisplays(harness) == [Self.second.id, nil], "once shown, the display is no longer asked for")
  }

  @Test("The wanted display stays on the regular heartbeats until a reply shows it")
  func keepsAskingUntilTheDisplayShows() async {
    let (harness, _) = await liveHarness()
    harness.host.displaySwitchAnswer = .stillSwitching

    harness.connection.switchDisplay(to: Self.second.id)
    await heartbeats(harness, answered: 1)
    #expect(harness.connection.displaySwitch?.phase == .switching && harness.connection.display == Self.first)

    harness.host.displaySwitchAnswer = .switches
    await harness.beat()
    await awaitObserved { harness.connection.displaySwitch?.phase == .confirmed }
    await harness.beat()

    #expect(askedDisplays(harness) == [Self.second.id, Self.second.id, nil])
    #expect(harness.connection.display == Self.second && harness.connection.preferredDisplayId == Self.second.id)
  }

  @Test("A display the host can't switch to is reported, the old display stays, and nothing is saved")
  func reportsADisplayTheHostCannotShare() async {
    let (harness, session) = await liveHarness()
    harness.host.displaySwitchAnswer = .unavailable(message: "That display is asleep.")

    harness.connection.switchDisplay(to: Self.second.id)
    await awaitObserved { harness.connection.displaySwitch?.phase != .switching }
    await harness.beat()

    let unavailable = Switch(
      displayId: Self.second.id, name: Self.second.name, phase: .unavailable(message: "That display is asleep."))
    #expect(harness.connection.displaySwitch == unavailable)
    #expect(harness.connection.display == Self.first && harness.connection.preferredDisplayId == nil)
    #expect(harness.connection.state == .live && !session.isClosed && harness.connection.hostNotice == nil)
    #expect(askedDisplays(harness) == [Self.second.id, nil])
    #expect(harness.clock.pendingCount == 1, "only the next heartbeat is waiting; the 15 s backstop is gone")
  }

  @Test("With no result after 15 s the old display is reported again; a host that gets there later is still followed")
  func givesUpAfterFifteenSeconds() async {
    let (harness, _) = await liveHarness()
    harness.host.displaySwitchAnswer = .stillSwitching

    harness.connection.switchDisplay(to: Self.second.id)
    await heartbeats(harness, answered: 1)
    await harness.clock.waitForSleep(ScreenSharingConnectionDeadlines.displaySwitch)
    await harness.beat()
    harness.clock.advance(by: .seconds(7) - .milliseconds(1))
    #expect(harness.connection.displaySwitch?.phase == .switching)
    harness.clock.advance(by: .milliseconds(1))
    await awaitObserved { harness.connection.displaySwitch?.phase == .unavailable(message: nil) }
    #expect(harness.connection.state == .live && harness.connection.preferredDisplayId == nil)

    harness.host.shareDisplay(Self.second.id)
    await harness.beat()
    await awaitObserved { harness.connection.displaySwitch?.phase == .confirmed }

    #expect(askedDisplays(harness) == [Self.second.id, Self.second.id, nil])
    #expect(harness.connection.display == Self.second && harness.connection.preferredDisplayId == Self.second.id)
  }

  @Test("Only one heartbeat that names a display is in flight; a second pick waits for its answer, then goes at once")
  func sendsOneDisplayHeartbeatAtATime() async {
    let (harness, _) = await liveHarness()
    harness.host.hold(.heartbeat)

    harness.connection.switchDisplay(to: Self.second.id)
    await awaitObserved { harness.host.requests(.heartbeat).count == 1 }
    harness.connection.switchDisplay(to: Self.third.id)
    await harness.tick()
    await awaitObserved { harness.host.requests(.heartbeat).count == 2 }
    #expect(askedDisplays(harness) == [Self.second.id, nil], "the regular heartbeat goes out plain meanwhile")
    #expect(
      harness.connection.displaySwitch == Switch(displayId: Self.third.id, name: Self.third.name, phase: .switching))

    harness.host.release(.heartbeat)
    await awaitObserved { harness.connection.displaySwitch?.phase == .confirmed }

    #expect(askedDisplays(harness) == [Self.second.id, nil, Self.third.id])
    #expect(harness.connection.display == Self.third && harness.connection.preferredDisplayId == Self.third.id)
  }

  @Test("Picking the old display back while a switch is in flight is not confirmed by an answer that predates it")
  func doesNotConfirmFromAnEarlierHeartbeat() async throws {
    let (harness, _) = await liveHarness()
    harness.host.hold(.heartbeat)

    harness.connection.switchDisplay(to: Self.second.id)
    await awaitObserved { harness.host.requests(.heartbeat).count == 1 }
    let held = try #require(harness.host.holdOnlyThoseWaiting(.heartbeat))
    harness.connection.switchDisplay(to: Self.first.id)
    await harness.tick()
    await heartbeats(harness, answered: 1)
    #expect(harness.connection.display == Self.first)
    #expect(
      harness.connection.displaySwitch == Switch(displayId: Self.first.id, name: Self.first.name, phase: .switching))

    held.signal()
    await awaitObserved { harness.connection.displaySwitch?.phase == .confirmed }

    #expect(askedDisplays(harness) == [Self.second.id, nil, Self.first.id])
    #expect(harness.connection.display == Self.first && harness.connection.preferredDisplayId == Self.first.id)
    #expect(harness.host.sharedDisplayId == Self.first.id)
  }

  @Test("A host that moves to another display by itself is followed, and the saved choice is left alone")
  func followsAHostThatMovedByItself() async {
    let (harness, session) = await liveHarness()
    let connection = harness.connection

    harness.host.shareDisplay(Self.second.id)
    await harness.beat()
    await awaitObserved { connection.display == Self.second }

    #expect(connection.displaySwitch == nil, "nothing was picked, so there is no switch to report")
    #expect(connection.preferredDisplayId == nil && connection.state == .live && !session.isClosed)
    #expect(askedDisplays(harness) == [nil] && harness.host.starts.count == 1)
  }

  @Test("A display from a heartbeat older than the newest one answered is ignored")
  func ignoresAStaleDisplay() async throws {
    let (harness, _) = await liveHarness()
    harness.host.hold(.heartbeat)
    await harness.tick()
    await awaitObserved { harness.host.requests(.heartbeat).count == 1 }
    let held = try #require(harness.host.holdOnlyThoseWaiting(.heartbeat))

    harness.host.shareDisplay(Self.second.id)
    await harness.tick()
    await awaitObserved { harness.connection.display == Self.second }

    harness.host.shareDisplay(Self.first.id)
    held.signal()
    await heartbeats(harness, answered: 2)

    #expect(harness.connection.display == Self.second, "the older heartbeat's answer is not shown")
  }

  @Test("A pick while the connection is still coming up opens the picked display, and is saved once it shows")
  func picksWhileConnecting() async {
    let host = FakeHost()
    host.displays = [Self.first, Self.second]
    let harness = ConnectionHarness(host: host)
    harness.show()

    harness.connection.switchDisplay(to: Self.second.id)
    #expect(harness.connection.preferredDisplayId == nil)
    #expect(harness.connection.displaySwitch?.phase == .switching)
    await harness.goLive()

    #expect(harness.host.starts.last?.displayId == Self.second.id)
    #expect(
      harness.connection.displaySwitch == Switch(displayId: Self.second.id, name: Self.second.name, phase: .confirmed))
    #expect(harness.connection.preferredDisplayId == Self.second.id)
  }

  @Test("A display that comes back leaves the Not Available list, and the next reply's list replaces it")
  func unavailableListFollowsTheDisplays() async {
    let host = FakeHost()
    host.displays = [Self.first]
    host.unavailable = [ServerScreenSharingUnavailableDisplay(id: Self.second.id, name: "Studio", problem: "Asleep.")]
    let harness = ConnectionHarness(host: host)
    harness.show()
    await harness.goLive()
    #expect(harness.connection.unavailableDisplays.map(\.id) == [Self.second.id])

    host.displays = [Self.first, Self.second]
    await harness.beat()
    await awaitObserved { harness.connection.displays.count == 2 }
    #expect(harness.connection.unavailableDisplays.isEmpty)

    host.displays = [Self.first]
    harness.connection.restart()
    await awaitObserved { harness.connection.unavailableDisplays.map(\.id) == [Self.second.id] }
  }

  @Test("A session that drops in the middle of a switch reports it as not done and reconnects on the saved display")
  func dropsAPendingSwitchWithTheSession() async {
    let (harness, session) = await liveHarness()
    harness.host.displaySwitchAnswer = .stillSwitching
    harness.connection.switchDisplay(to: Self.second.id)
    await heartbeats(harness, answered: 1)

    session.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    #expect(
      harness.connection.displaySwitch
        == Switch(displayId: Self.second.id, name: Self.second.name, phase: .unavailable(message: nil)))
    await harness.goLive()

    #expect(harness.host.starts.map(\.displayId) == [nil, nil] && harness.connection.preferredDisplayId == nil)
  }
}
