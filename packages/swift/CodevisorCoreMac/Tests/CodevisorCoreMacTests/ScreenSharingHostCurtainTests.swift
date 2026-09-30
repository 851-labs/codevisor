import CoreGraphics
import Testing

@testable import CodevisorCoreMac

/// 851-2382: the host's screens go dark while it's controlled and come back when control ends.
/// A recording stands in for the displays, so nothing on the Mac running the tests goes dark.
@MainActor
struct ScreenSharingHostCurtainTests {
  @MainActor final class Displays {
    var physical: [CGDirectDisplayID] = [1, 2]
    private(set) var darkened: [CGDirectDisplayID] = []
    private(set) var restores = 0
    var system: ScreenSharingHostCurtain.System {
      .init(
        physicalDisplays: { self.physical }, darken: { self.darkened.append($0) }, restore: { self.restores += 1 })
    }
  }

  @Test func drawingDarkensEveryPhysicalDisplayAndOpeningRestoresOnce() {
    let displays = Displays()
    let curtain = ScreenSharingHostCurtain(system: displays.system)
    curtain.draw()
    #expect(curtain.isDrawn && displays.darkened == [1, 2])
    curtain.open()
    curtain.open()
    #expect(!curtain.isDrawn && displays.restores == 1)
  }

  @Test func aDisplayChangeDarkensAgainOnlyWhileDrawn() {
    let displays = Displays()
    let curtain = ScreenSharingHostCurtain(system: displays.system)
    curtain.displaysChanged()
    #expect(displays.darkened.isEmpty, "not controlled: nothing to darken")
    curtain.draw()
    displays.physical = [3]  // a display plugged in, or renumbered, while controlled
    curtain.displaysChanged()
    #expect(displays.darkened == [1, 2, 3])
    curtain.open()
    curtain.displaysChanged()
    #expect(displays.darkened == [1, 2, 3], "open: display changes leave the screens alone")
    #expect(displays.restores == 1)
  }
}
