import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: open and attach", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionIntentTests {
  @Test(
    "Opening the desktop in a tab, window or phone screen asks to take over",
    arguments: [ScreenSharingSurfaceKind.tab, .window, .phone])
  func opensWithTheUsersAction(_ kind: ScreenSharingSurfaceKind) async {
    let harness = ConnectionHarness()
    harness.open(kind)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.open])
  }

  @Test("A surface that merely comes on screen attaches without taking over")
  func attachesWhenASurfaceBecomesVisible() async {
    let harness = ConnectionHarness()
    harness.show(.tab)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("The preview and PiP never take over", arguments: [ScreenSharingSurfaceKind.preview, .pictureInPicture])
  func neverOpensFromAPassiveSurface(_ kind: ScreenSharingSurfaceKind) async {
    let harness = ConnectionHarness()
    harness.open(kind)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("An open that loses a race to another app is in use like any other, and View here asks to take over again")
  func failsAnOpenThatLosesARace() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    let tab = harness.open(.tab)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    tab.viewHere()
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.open, .open])
  }

  struct Refused: Sendable, CustomTestStringConvertible {
    var status: String
    var reason: String
    var testDescription: String { reason }
  }

  nonisolated static let refusedUntilOpened = [
    Refused(status: "busy", reason: "in-use"), Refused(status: "failed", reason: "stopped-on-host"),
    Refused(status: "failed", reason: "display-asleep"), Refused(status: "failed", reason: "session-switched"),
  ]

  @Test(
    "Opening the desktop while a passive attach is being refused asks again, this time to take over",
    arguments: refusedUntilOpened)
  func takesOverWhenTheUserOpensDuringARefusedAttach(_ refused: Refused) async {
    let harness = ConnectionHarness()
    harness.host.hold(.start)
    harness.host.answerNext(.start, .reply(status: refused.status, reason: refused.reason))
    harness.show(.preview)
    await awaitObserved { harness.host.starts.count == 1 }

    harness.open(.window)
    harness.host.release(.start)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
    #expect(harness.host.stops.isEmpty, "the connection never failed in between")
  }

  @Test("An Open Desktop on a surface that never comes on screen is not spent by a preview that does")
  func keepsAnOpenForTheSurfaceThatAsked() async {
    let harness = ConnectionHarness()
    let tab = harness.connection.attach(.tab)
    tab.openedByUser()
    harness.show(.preview)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test(
    "An Open Desktop counts for 5 s, until its surface is on screen",
    arguments: [(Duration.seconds(5), ScreenSharingStartIntent.open), (.milliseconds(5001), .attach)])
  func forgetsAnOpenAfterFiveSeconds(wait: Duration, expected: ScreenSharingStartIntent) async {
    let harness = ConnectionHarness()
    let tab = harness.connection.attach(.tab)
    tab.openedByUser()
    harness.clock.advance(by: wait)
    tab.setOnScreen(true)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [expected])
  }

  @Test("An Open Desktop is forgotten when its surface goes off screen or detaches", arguments: [false, true])
  func forgetsAnOpenWhenItsSurfaceLeaves(detaching: Bool) async {
    let harness = ConnectionHarness()
    harness.host.hold(.start)
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    harness.show(.preview)
    await awaitObserved { harness.host.starts.count == 1 }

    let window = harness.open(.window)
    if detaching {
      window.detach()
    } else {
      window.setOnScreen(false)
    }
    harness.host.release(.start)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("Opening the desktop while the preview shows it in use on another device takes over")
  func takesOverWhenTheUserOpensAfterARefusedAttach() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    harness.show(.preview)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    harness.open(.window)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
  }
}
