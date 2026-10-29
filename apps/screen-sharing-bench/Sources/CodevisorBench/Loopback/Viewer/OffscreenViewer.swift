import CoreGraphics
import ScreenSharing

@MainActor
final class OffscreenViewer: LoopbackViewer {
  private static let clearColor = SIMD4<Double>(0.025, 0.025, 0.025, 1)

  private let coordinator: ScreenSharingRenderCoordinator
  private let preparer: OffscreenPreparer
  private let geometry: ScreenSharingRenderGeometry

  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, drawableSize: CGSize) throws {
    coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: metrics, renderOnArrival: true, redrawsOnDemand: true)
    preparer = try OffscreenPreparer()
    geometry = ScreenSharingRenderGeometry(clearColor: Self.clearColor, drawableSize: drawableSize)
    coordinator.bind { [weak self] in self?.draw() }
  }

  func stop() {
    coordinator.stop()
  }

  private func draw() {
    coordinator.prepare(with: preparer, geometry: geometry)
  }
}
