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

  @Test("A shared display that is gone is told apart from one that only got a new number")
  func successor() {
    typealias Identity = ScreenSharingDisplayIdentity
    let builtIn = Self.online(1, Self.otherDisplay, main: true)
    let projector = Self.online(7, Identity(vendor: 0x4C2D, model: 9, serial: 3))
    let hostVirtual = Self.online(129, Self.virtual, virtual: true)

    #expect(Identity.successor(of: 188, identity: Self.studioDisplay, online: [builtIn]) == .another(1))
    #expect(Identity.successor(of: 188, identity: Self.studioDisplay, online: [projector, builtIn]) == .another(1))
    #expect(Identity.successor(of: 188, identity: Self.studioDisplay, online: [projector, hostVirtual]) == .another(7))
    #expect(Identity.successor(of: 188, identity: Self.studioDisplay, online: [hostVirtual]) == Identity.Successor.none)

    let renumbered = [builtIn, Self.online(190, Self.studioDisplay)]
    #expect(Identity.successor(of: 188, identity: Self.studioDisplay, online: renumbered) == .renumbered(190))
    #expect(Identity.successor(of: 1, identity: Self.otherDisplay, online: renumbered) == .unchanged)
  }

  @Test("A display with the shared one's identity but another size is moved to, not renumbered and not skipped")
  func sameIdentityAnotherSize() {
    typealias Identity = ScreenSharingDisplayIdentity
    let landscape = Identity.Pixels(width: 2560, height: 1440)
    let builtIn = Self.online(1, Self.otherDisplay, main: true)
    var alike = Self.online(190, Self.studioDisplay)

    alike.pixels = Identity.Pixels(width: 1440, height: 2560)
    #expect(
      Identity.successor(of: 188, identity: Self.studioDisplay, pixels: landscape, online: [builtIn, alike])
        == .another(190), "it stays with its own display, at that display's size, instead of going to the main one")

    alike.pixels = landscape
    #expect(
      Identity.successor(of: 188, identity: Self.studioDisplay, pixels: landscape, online: [builtIn, alike])
        == .renumbered(190))
    #expect(
      Identity.successor(of: 188, identity: Self.studioDisplay, pixels: nil, online: [builtIn, alike])
        == .renumbered(190), "with no size on record the identity decides, as before")
  }

  @Test("A headless Mac's framebuffer is the same display whatever size it comes back at")
  func headlessFramebufferIgnoresSize() {
    typealias Identity = ScreenSharingDisplayIdentity
    let framebuffer = Identity(
      vendor: Identity.headlessFramebuffer.vendor, model: Identity.headlessFramebuffer.model, serial: 0)
    var back = Self.online(46, framebuffer, main: true)
    back.pixels = Identity.Pixels(width: 1280, height: 720)
    let shared = Identity.Pixels(width: 1920, height: 1080)

    #expect(Identity.successor(of: 44, identity: framebuffer, pixels: shared, online: [back]) == .renumbered(46))
  }

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
