import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostRetinaTests {
  private static let headless = ScreenSharingHostRetina.SharedDisplay(
    width: 1920, height: 1080, pixelScale: 1, isHeadless: true)

  private static func size(
    dynamic: (width: Int, height: Int)? = nil, _ shared: ScreenSharingHostRetina.SharedDisplay = headless,
    available: Bool = true
  ) -> (width: Int, height: Int)? {
    ScreenSharingHostRetina.virtualDisplaySize(dynamic: dynamic, shared: shared, virtualDisplaysAvailable: available)
  }

  @Test func aHeadlessOneXDisplayStreamsAtTwiceItsOwnPointSize() throws {
    #expect(try #require(Self.size()) == (1920, 1080))
    var smaller = Self.headless
    (smaller.width, smaller.height) = (1280, 720)
    #expect(try #require(Self.size(smaller)) == (1280, 720))
  }

  @Test func retinaDisplaysAndDisplaysWithAMonitorStreamAsTheyAre() {
    var retina = Self.headless
    retina.pixelScale = 2
    #expect(Self.size(retina) == nil)
    var monitor = Self.headless
    monitor.isHeadless = false
    #expect(Self.size(monitor) == nil)
  }

  @Test func oneXStaysWhenTwoXWouldChangeTheLayoutOrNoVirtualDisplayCanBeMade() {
    var wide = Self.headless
    (wide.width, wide.height) = (2560, 1440)
    #expect(Self.size(wide) == nil)
    var tall = Self.headless
    (tall.width, tall.height) = (1920, 1200)
    #expect(Self.size(tall) == nil)
    #expect(Self.size(available: false) == nil)
  }

  @Test func dynamicResolutionSizesToTheWindowOnEveryDisplay() throws {
    var monitor = Self.headless
    monitor.isHeadless = false
    monitor.pixelScale = 2
    #expect(try #require(Self.size(dynamic: (1281, 801), monitor)) == (1280, 800))
    #expect(try #require(Self.size(dynamic: (1281, 801))) == (1280, 800))
    #expect(try #require(Self.size(dynamic: (5000, 2500))) == (1920, 960))
  }

  @Test func onlyMacOSsMonitorlessFramebufferCountsAsHeadless() {
    #expect(ScreenSharingDisplayIdentity(vendor: 0x756E_6B6E, model: 0x7669_7274, serial: 0).isHeadlessFramebuffer)
    #expect(!ScreenSharingDisplayIdentity(vendor: 0x610, model: 0xA050, serial: 0).isHeadlessFramebuffer)
    #expect(
      !ScreenSharingDisplayIdentity(vendor: ScreenSharingHostVirtualDisplay.vendorID, model: 1, serial: 1)
        .isHeadlessFramebuffer)
  }
}
