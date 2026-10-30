import Testing

@testable import ScreenSharing

@Suite @MainActor struct ScreenSharingVideoSurfaceRendererTests {
  @Test func theVideoSurfaceUsesTheWorkerPathAndAPlainMetalViewStaysOnTheMainActor() throws {
    let product = ScreenSharingMetrics()
    let pane = try ScreenSharingVideoSurface(mailbox: ScreenSharingFrameMailbox(), metrics: product)
    var labels = product.snapshot().labels
    #expect(labels["renderPreparation"] == "off-main serial worker")
    #expect(
      labels["drawableAcquisitionPath"]
        == "CAMetalDisplayLink drawable (frame latency 1), used until half the time to its refresh")
    #expect(labels["maximumDrawableCount"] == "3")
    #expect(labels["frameSelection"] == "before drawable acquisition")
    pane.stop()
    #expect(product.snapshot().labels["rendererStopped"] == "true")
    pane.stop()

    let plain = ScreenSharingMetrics()
    let standard = try ScreenSharingMetalView(mailbox: ScreenSharingFrameMailbox(), metrics: plain)
    labels = plain.snapshot().labels
    #expect(labels["renderPreparation"] == "main actor (MTKView)")
    #expect(labels["drawableAcquisitionPath"] == "MTKView.currentDrawable on main actor")
    #expect(labels["maximumDrawableCount"] == "3")
    standard.stop()
  }
}
