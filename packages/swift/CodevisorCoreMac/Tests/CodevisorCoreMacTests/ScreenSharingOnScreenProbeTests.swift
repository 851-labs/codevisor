import AppKit
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingOnScreenProbeTests {
  private let probe = ScreenSharingOnScreenProbe()
  private let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))
  private let window = StagedWindow()

  @Test func isOnScreenOnlyWhileShownInAWindowWithASize() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    container.addSubview(probe)
    probe.setFrameSize(container.bounds.size)
    #expect(reports.isEmpty, "a view that was never put in a window, like a closed inspector's, is not on screen")

    window.contentView?.addSubview(container)
    #expect(reports == [true])
    container.isHidden = true
    #expect(reports == [true, false], "closing the inspector hides an ancestor")
    container.isHidden = false
    probe.setFrameSize(.zero)
    probe.setFrameSize(container.bounds.size)
    #expect(reports == [true, false, true, false, true])
    container.removeFromSuperview()
    #expect(reports == [true, false, true, false, true, false])
  }

  @Test func aMinimisedWindowIsNotOnScreen() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    probe.setFrameSize(container.bounds.size)
    window.contentView?.addSubview(probe)

    window.minimise(true)
    #expect(reports == [true, false])
    window.minimise(false)
    #expect(reports == [true, false, true])
  }

  @Test func aWindowThatIsNotShowingYetOrWasOrderedOutIsNotOnScreen() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    probe.setFrameSize(container.bounds.size)
    window.shows = false
    window.contentView?.addSubview(probe)
    #expect(reports.isEmpty, "the view is built before its window is ordered front")

    window.shows = true
    #expect(reports == [true])
    window.shows = false
    #expect(reports == [true, false], "a hidden app or a closed window orders its windows out")
  }

  @Test func hidingTheAppTakesItsWindowsOffScreenAndUnhidingBringsThemBack() {
    var reports: [Bool] = []
    var appIsHidden = false
    probe.onChange = { reports.append($0) }
    probe.isApplicationHidden = { appIsHidden }
    probe.setFrameSize(container.bounds.size)
    window.contentView?.addSubview(probe)

    appIsHidden = true
    NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
    #expect(reports == [true, false], "even when the window's own visibility says nothing")
    appIsHidden = false
    NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
    #expect(reports == [true, false, true])

    probe.removeFromSuperview()
    appIsHidden = true
    NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
    #expect(reports == [true, false, true, false], "leaving the window is the last thing it reports")
  }

  @Test func stopsFollowingAWindowItLeft() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    probe.setFrameSize(container.bounds.size)
    window.contentView?.addSubview(probe)
    probe.removeFromSuperview()

    window.minimise(true)
    window.shows = false
    #expect(reports == [true, false])
  }

  @Test func retiringReportsOffScreenOnceAndThenStaysQuiet() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    probe.setFrameSize(container.bounds.size)
    window.contentView?.addSubview(probe)
    probe.retire()
    window.minimise(true)
    probe.removeFromSuperview()
    #expect(reports == [true, false])
  }
}
