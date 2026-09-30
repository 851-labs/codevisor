import CoreGraphics
import Testing

@testable import CodevisorCoreMac

@Suite("Screen sharing follows its display across renumbering")
struct ScreenSharingDisplayIdentityTests {
  static let studioDisplay = ScreenSharingDisplayIdentity(vendor: 0x610, model: 0xAE31, serial: 1)
  static let otherDisplay = ScreenSharingDisplayIdentity(vendor: 0x610, model: 0xAE31, serial: 2)
  static let virtual = ScreenSharingDisplayIdentity(vendor: 0xC0DF, model: 1, serial: 1)

  static func online(
    _ id: CGDirectDisplayID, _ identity: ScreenSharingDisplayIdentity, main: Bool = false, virtual: Bool = false
  ) -> ScreenSharingDisplayIdentity.Online {
    .init(id: id, identity: identity, isMain: main, isVirtual: virtual)
  }

  @Test("A display that is still online keeps its ID")
  func unchanged() {
    let online = [Self.online(188, Self.studioDisplay, main: true)]
    #expect(ScreenSharingDisplayIdentity.follow(188, identity: Self.studioDisplay, online: online) == 188)
  }

  @Test("A renumbered display is found by its hardware identity, never the host's virtual display")
  func renumbered() {
    // The Mac Studio case: 188 came back as 190 after the virtual display came and went.
    let online = [
      Self.online(191, Self.virtual, virtual: true),
      Self.online(190, Self.studioDisplay, main: true),
      Self.online(192, Self.otherDisplay),
    ]
    #expect(ScreenSharingDisplayIdentity.follow(188, identity: Self.studioDisplay, online: online) == 190)
  }

  @Test("Displays that can't be told apart fall back to the only physical one, then the main one")
  func indistinguishable() {
    let dummy = ScreenSharingDisplayIdentity(vendor: 0, model: 0, serial: 0)
    // A headless Mac's dummy display reports no identity at all.
    #expect(
      ScreenSharingDisplayIdentity.follow(188, identity: dummy, online: [Self.online(190, dummy, main: true)]) == 190)
    let twins = [Self.online(190, dummy), Self.online(191, dummy, main: true)]
    #expect(ScreenSharingDisplayIdentity.follow(188, identity: dummy, online: twins) == 191)
  }

  @Test("Mid-change, with no physical display listed, there is nothing to follow yet")
  func midChange() {
    #expect(ScreenSharingDisplayIdentity.follow(188, identity: Self.studioDisplay, online: []) == nil)
    let onlyVirtual = [Self.online(191, Self.virtual, virtual: true)]
    #expect(ScreenSharingDisplayIdentity.follow(188, identity: Self.studioDisplay, online: onlyVirtual) == nil)
  }

  /// tuftlord, alpha 1118: a late display-change notification from the host's own virtual display
  /// ended a session 3 s in. A change that leaves the shared and virtual displays online doesn't.
  @Test("A display change that keeps both displays online doesn't end the session")
  func survivesOwnChange() {
    let online = [Self.online(1, Self.studioDisplay, main: true), Self.online(129, Self.virtual, virtual: true)]
    #expect(
      ScreenSharingDisplayIdentity.sessionSurvives(
        shared: 1, identity: Self.studioDisplay, virtual: 129, online: online))
    #expect(
      ScreenSharingDisplayIdentity.sessionSurvives(
        shared: 1, identity: Self.studioDisplay, virtual: nil, online: online))
  }

  @Test("Losing the shared display, or the virtual display it mirrors onto, ends the session")
  func endsWhenDisplaysGo() {
    let noPhysical = [Self.online(129, Self.virtual, virtual: true)]
    #expect(
      !ScreenSharingDisplayIdentity.sessionSurvives(
        shared: 1, identity: Self.studioDisplay, virtual: 129, online: noPhysical))
    let noVirtual = [Self.online(1, Self.studioDisplay, main: true)]
    #expect(
      !ScreenSharingDisplayIdentity.sessionSurvives(
        shared: 1, identity: Self.studioDisplay, virtual: 129, online: noVirtual))
  }
}
