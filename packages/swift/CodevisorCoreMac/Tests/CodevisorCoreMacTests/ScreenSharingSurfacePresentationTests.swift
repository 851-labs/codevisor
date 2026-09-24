import AppKit
import ScreenSharing
import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The real Metal surface in a real window, fed one BGRA frame the way the
/// VNC session feeds it. Needs a window server, so it runs only with
/// SCREEN_SHARING_WINDOW_TESTS=1.
@MainActor
struct ScreenSharingSurfacePresentationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SCREEN_SHARING_WINDOW_TESTS"] == "1"), arguments: [false, true])
  func oneFramePresentsAndReportsReady(publishBeforeWindow: Bool) async throws {
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    let surface = try ScreenSharingVideoSurface(mailbox: mailbox, metrics: metrics)
    var presentations = 0
    surface.onPresented = { presentations += 1 }
    let framebuffer = try RFBFramebuffer(width: 1440, height: 900)
    try framebuffer.fill(RFBRectangle(x: 0, y: 0, width: 1440, height: 900), blue: 200, green: 120, red: 40)
    let publisher = VNCFramePublisher()
    if publishBeforeWindow { publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics) }
    let window = NSWindow(
      contentRect: NSRect(x: 40, y: 40, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.title = "presentation test"
    window.contentView = surface.view
    window.makeKeyAndOrderFront(nil)
    if !publishBeforeWindow {
      try? await Task.sleep(for: .milliseconds(300))
      publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics)
    }
    let presented = await awaitPolled(timeout: .seconds(6)) { presentations > 0 }
    let counters = metrics.snapshot().counters.filter {
      [
        "presentedFrames", "presentationCallbacks", "unpresentedDrawables", "renderDrops", "renderedFrames",
        "renderErrors", "vncUpdatesPublished",
      ].contains($0.key)
    }
    print(
      "presentation(publishBeforeWindow=\(publishBeforeWindow)): presented=\(presented) presentations=\(presentations) counters=\(counters) labels=\(metrics.snapshot().labels["videoSize"] ?? "-")"
    )
    surface.stop()
    window.orderOut(nil)
    #expect(presented)
  }
}
