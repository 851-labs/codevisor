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
    _ = harness.show(.tab)
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

  @Test("Opening the desktop while a passive attach is being refused asks again, this time to take over")
  func takesOverWhenTheUserOpensDuringARefusedAttach() async {
    let harness = ConnectionHarness()
    harness.host.hold(.start)
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    _ = harness.show(.preview)
    await awaitObserved { harness.host.starts.count == 1 }

    harness.open(.window)
    harness.host.release(.start)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
    #expect(harness.host.requests(.stop).isEmpty, "the connection never failed in between")
  }

  @Test("Opening the desktop while the preview shows it in use on another device takes over")
  func takesOverWhenTheUserOpensAfterARefusedAttach() async {
    let harness = ConnectionHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's iPhone"))
    _ = harness.show(.preview)
    await harness.settle(.failed(.inUse(by: "Alexandru's iPhone")))

    harness.open(.window)
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
  }
}
