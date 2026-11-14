import AppKit
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingOnScreenProbeTests {
  private let probe = ScreenSharingOnScreenProbe()
  private let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)

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

  @Test func retiringReportsOffScreenOnceAndThenStaysQuiet() {
    var reports: [Bool] = []
    probe.onChange = { reports.append($0) }
    probe.setFrameSize(container.bounds.size)
    window.contentView?.addSubview(probe)
    probe.retire()
    probe.removeFromSuperview()
    #expect(reports == [true, false])
  }
}
