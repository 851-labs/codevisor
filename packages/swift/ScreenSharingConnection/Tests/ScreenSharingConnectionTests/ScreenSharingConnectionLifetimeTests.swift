import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: lifetime and surfaces", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionLifetimeTests {
  private static let linger = ScreenSharingConnectionDeadlines.linger
  private static let debounce = ScreenSharingConnectionDeadlines.unseenDebounce

  @Test("A surface that is attached but never reported visible never starts a connection, whatever else happens")
  func neverStartsForASurfaceNobodySees() async {
    let harness = ConnectionHarness()
    let preview = harness.connection.attach(.preview)
    preview.size = ScreenSharingSurfaceSize(width: 320, height: 200, scale: 2)
    preview.setOnScreen(false)
    preview.retry()
    harness.manager.machineCameOnline(ConnectionHarness.machineId)
    harness.manager.systemWoke()
    harness.connection.attach(.tab).detach()

    #expect(harness.connection.state == .off)
    #expect(harness.host.requests.isEmpty && harness.clock.pendingCount == 0, "nothing was sent or scheduled")
  }

  private func leave(_ surface: ScreenSharingSurface, detaching: Bool) {
    if detaching {
      surface.detach()
    } else {
      surface.setOnScreen(false)
    }
  }

  enum Phase: CaseIterable, Sendable { case connecting, live, failedInUse }

  @Test(
    "Switching workspace, where one surface leaves 200 ms before the next is on screen, changes nothing",
    arguments: Phase.allCases, [false, true])
  func survivesAWorkspaceSwitch(_ phase: Phase, detaching: Bool) async {
    let harness = ConnectionHarness()
    if phase == .failedInUse {
      harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    }
    let first = harness.show(.preview)
    switch phase {
    case .connecting:
      _ = await harness.startedSession()
    case .live:
      await harness.goLive()
    case .failedInUse:
      await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))
      await awaitObserved { harness.host.requests(.stop).count == 1 }
    }
    let state = harness.connection.state
    let sent = harness.host.requests.count

    leave(first, detaching: detaching)
    await harness.clock.waitForSleep(Self.debounce)
    harness.clock.advance(by: .milliseconds(200))
    harness.show(.preview)
    harness.clock.advance(by: Self.debounce)

    #expect(harness.connection.state == state)
    #expect(harness.host.requests.count == sent && harness.media.sessions.allSatisfy { !$0.isClosed })
    #expect(harness.clock.requestCount(Self.linger) == 0, "the 60 s linger never started")
  }

  @Test("Nothing visible for 2 s while connecting cancels the attempt, stops it on the host and turns off")
  func givesUpConnectingWhenNobodyLooks() async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    let session = await harness.startedSession()

    surface.setOnScreen(false)
    await harness.clock.waitForSleep(Self.debounce)
    harness.clock.advance(by: Self.debounce - .milliseconds(1))
    #expect(harness.connection.state == .connecting(.waitingForVideo) && !session.isClosed)
    harness.clock.advance(by: .milliseconds(1))
    await harness.settle(.off)
    await awaitObserved { harness.host.requests(.stop).count == 1 }

    #expect(session.isClosed)
    await harness.noTimersLeft()
    #expect(harness.host.requests(.stop)[0].viewerId == harness.host.starts[0].viewerId)
  }

  @Test(
    "Nothing visible while live turns the connection off after 2 s plus the 60 s linger, and stops the host",
    arguments: [false, true])
  func turnsOffAfterTheLinger(detaching: Bool) async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    let session = await harness.goLive()

    leave(surface, detaching: detaching)
    await harness.elapse(Self.debounce)
    await harness.clock.waitForSleep(Self.linger)
    await harness.stayLive(for: Self.linger - .milliseconds(1))
    #expect(harness.connection.state == .live && !session.isClosed)
    harness.clock.advance(by: .milliseconds(1))
    await harness.settle(.off)
    await awaitObserved { harness.host.requests(.stop).count == 1 }

    #expect(session.isClosed && harness.connection.session == nil)
    #expect(harness.host.requests(.stop)[0].viewerId == harness.host.starts[0].viewerId)
  }

  @Test("A surface that shows up during the linger keeps the connection, and hiding again starts over")
  func keepsTheConnectionWhenASurfaceReturns() async {
    let harness = ConnectionHarness()
    let preview = harness.show(.preview)
    let session = await harness.goLive()

    preview.setOnScreen(false)
    await harness.elapse(Self.debounce)
    await harness.clock.waitForSleep(Self.linger)
    await harness.stayLive(for: Self.linger - .milliseconds(1))
    let window = harness.show(.window)
    harness.clock.advance(by: .milliseconds(1))
    #expect(harness.connection.state == .live && !session.isClosed)

    window.setOnScreen(false)
    await harness.clock.waitForSleep(Self.debounce, count: 2)
    #expect(harness.host.starts.count == 1 && harness.host.requests(.stop).isEmpty)
  }

  @Test(
    "While reconnecting, a hidden surface keeps the 60 s linger, but with no surface left it turns off after 2 s",
    arguments: [false, true])
  func lingersWhileReconnectingOnlyWithASurface(detaching: Bool) async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    let session = await harness.goLive()
    harness.host.hold(.capabilities)
    session.host.report(connection: "failed")
    await awaitObserved { harness.host.requests(.capabilities).count == 2 }

    leave(surface, detaching: detaching)
    await harness.elapse(Self.debounce)
    if !detaching {
      await harness.clock.waitForSleep(Self.linger)
      #expect(harness.connection.state == .reconnecting)
      harness.clock.advance(by: Self.linger)
    }
    await harness.settle(.off)
  }

  @Test("A failed connection nobody sees for 2 s turns off, and the next visible surface connects afresh")
  func turnsOffAFailedConnectionNobodyLooksAt() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.capabilities, .reply(status: "permission-required", reason: "permission-missing"))
    let surface = harness.show()
    await harness.settle(.failed(.permissionMissing))

    surface.setOnScreen(false)
    await harness.clock.waitForSleep(Self.debounce)
    harness.clock.advance(by: Self.debounce - .milliseconds(1))
    #expect(harness.connection.state == .failed(.permissionMissing))
    harness.clock.advance(by: .milliseconds(1))
    await harness.settle(.off)
    surface.setOnScreen(true)
    await harness.goLive()
  }

  @Test("A surface that is dropped without detaching counts as gone, so the connection lingers and turns off")
  func noticesASurfaceThatWasDropped() async {
    let harness = ConnectionHarness()
    var surface: ScreenSharingSurface? = harness.connection.attach(.tab)
    surface?.setOnScreen(true)
    let session = await harness.goLive()

    surface = nil
    await awaitObserved { harness.connection.surfaces.isEmpty }
    await harness.elapse(Self.debounce)
    await harness.clock.waitForSleep(Self.linger)
    await harness.stayLive(for: Self.linger)
    await harness.settle(.off)
    await awaitObserved { harness.host.stops.count == 1 }

    #expect(session.isClosed)
  }

  @Test("A second surface attaching, opening, resizing and replacing the first sends nothing while live")
  func attachesMoreSurfacesWithoutTheNetwork() async {
    let harness = ConnectionHarness()
    let preview = harness.show(.preview)
    let session = await harness.goLive()
    let sent = harness.host.requests.count

    let window = harness.connection.attach(.window)
    window.openedByUser()
    window.setOnScreen(true)
    window.size = ScreenSharingSurfaceSize(width: 1440, height: 900, scale: 2)
    preview.detach()

    #expect(harness.connection.state == .live && harness.connection.session === session)
    #expect(harness.host.requests.count == sent && harness.media.sessions.count == 1)
    #expect(harness.connection.surfaces.map(\.id) == [window.id])
  }

  @Test("A second surface that appears while connecting does not start a second session")
  func sharesOneAttemptBetweenSurfaces() async {
    let harness = ConnectionHarness()
    harness.show(.preview)
    harness.show(.tab)
    await harness.goLive()

    #expect(harness.host.starts.count == 1 && harness.media.sessions.count == 1)
  }

  @Test("The manager hands out one connection per machine")
  func managesOneConnectionPerMachine() async {
    let harness = ConnectionHarness()
    let base = harness.machine
    let other = ScreenSharingMachine(
      id: "tamale", channel: base.channel, connector: base.connector, appName: base.appName, signer: base.signer,
      installId: base.installId, liveWorkspace: base.liveWorkspace)

    #expect(harness.manager.connection(for: harness.machine) === harness.connection)
    #expect(harness.manager.connection(for: other) !== harness.connection)
  }

  enum Ending: CaseIterable, Sendable { case machineRemoved, shutDown }
  enum Moment: CaseIterable, Sendable { case connecting, live }

  @Test(
    "Removing the machine or shutting down ends its connection for good, and surfaces can see that",
    arguments: Ending.allCases, Moment.allCases)
  func endsAConnectionForGood(_ ending: Ending, during moment: Moment) async {
    let harness = ConnectionHarness()
    let surface = harness.show()
    let ended = surface.connection
    let session = moment == .live ? await harness.goLive() : await harness.startedSession()

    switch ending {
    case .machineRemoved: harness.manager.remove(ConnectionHarness.machineId)
    case .shutDown: harness.manager.shutdown()
    }
    #expect(ended.state == .off && ended.isEnded && session.isClosed)
    await awaitObserved { harness.host.stops.count == 1 }
    let sent = harness.host.requests.count
    surface.setOnScreen(false)
    surface.setOnScreen(true)
    surface.retry()

    #expect(ended.state == .off && harness.host.requests.count == sent, "an ended connection never starts again")
    await harness.noTimersLeft()
    #expect(harness.connection !== ended && !harness.connection.isEnded, "the manager hands out a fresh one")
  }
}
