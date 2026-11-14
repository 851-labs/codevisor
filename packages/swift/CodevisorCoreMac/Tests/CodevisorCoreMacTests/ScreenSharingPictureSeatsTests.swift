import Foundation
import Testing

@testable import CodevisorCoreMac

struct ScreenSharingPictureSeatsTests {
  private let preview = UUID()
  private let tab = UUID()
  private let otherTab = UUID()
  private let window = UUID()

  @Test func theFirstTabOrWindowHoldsThePictureAndAPreviewNeverDoes() {
    var seats = ScreenSharingPictureSeats()
    seats.join(preview, role: .watcher)
    seats.setOnScreen(true, for: preview)
    seats.claim(preview)
    #expect(seats.holder == nil)

    seats.join(tab, role: .tab)
    #expect(seats.holder == tab, "even before it is on screen, so its video view exists when it is")
  }

  @Test func aSurfaceComingOnScreenTakesThePictureFromAHiddenOneOrAnEqualOne() {
    var seats = ScreenSharingPictureSeats()
    seats.join(tab, role: .tab)
    seats.join(otherTab, role: .tab)
    seats.setOnScreen(true, for: otherTab)
    #expect(seats.holder == otherTab)

    seats.setOnScreen(true, for: tab)
    #expect(seats.holder == tab)
  }

  @Test func aDesktopWindowKeepsThePictureOverATabUntilItHidesOrLeaves() {
    var seats = ScreenSharingPictureSeats()
    seats.join(tab, role: .tab)
    seats.setOnScreen(true, for: tab)
    seats.join(window, role: .window)
    seats.setOnScreen(true, for: window)
    #expect(seats.holder == window)

    seats.setOnScreen(false, for: tab)
    seats.setOnScreen(true, for: tab)
    #expect(seats.holder == window)

    seats.setOnScreen(false, for: window)
    #expect(seats.holder == tab)
    seats.setOnScreen(true, for: window)
    seats.leave(window)
    #expect(seats.holder == tab)
  }

  @Test func hidingTheHolderKeepsThePictureUnlessAnotherSurfaceIsOnScreen() {
    var seats = ScreenSharingPictureSeats()
    seats.join(tab, role: .tab)
    seats.setOnScreen(true, for: tab)
    seats.join(otherTab, role: .tab)

    seats.setOnScreen(false, for: tab)
    #expect(seats.holder == tab)

    seats.leave(tab)
    #expect(seats.holder == otherTab, "a hidden surface inherits it when nothing else is left")
    seats.leave(otherTab)
    #expect(seats.holder == nil)
  }

  @Test func takingControlMovesThePictureAndTheLastToTakeItIsNextInLine() {
    var seats = ScreenSharingPictureSeats()
    for id in [tab, otherTab] {
      seats.join(id, role: .tab)
      seats.setOnScreen(true, for: id)
    }
    seats.join(window, role: .window)
    seats.setOnScreen(true, for: window)

    seats.claim(tab)
    #expect(seats.holder == tab)
    seats.claim(window)
    seats.leave(window)
    #expect(seats.holder == tab)
  }

  @Test func soundPlaysOnlyWhileATabOrWindowIsOnScreen() {
    var seats = ScreenSharingPictureSeats()
    seats.join(preview, role: .watcher)
    seats.setOnScreen(true, for: preview)
    seats.join(tab, role: .tab)
    #expect(!seats.playsSound)

    seats.setOnScreen(true, for: tab)
    #expect(seats.playsSound)
    seats.setOnScreen(false, for: tab)
    #expect(!seats.playsSound)
  }
}
