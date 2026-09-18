import AppKit
import ScreenSharing
import QuartzCore

/// Owns the probe's alternative display driver. The application still uses
/// MTKView's ordinary scheduling unless this standalone experiment is selected.
@MainActor
final class ProbeMetalDisplayLink: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
  private weak var view: ScreenSharingMetalView?
  private let link: CAMetalDisplayLink

  init(view: ScreenSharingMetalView, framesPerSecond: Int) throws {
    guard let layer = view.layer as? CAMetalLayer else {
      throw ScreenSharingError.unavailable("The probe viewer has no Metal layer.")
    }
    self.view = view
    link = CAMetalDisplayLink(metalLayer: layer)
    super.init()
    view.isPaused = true
    view.enableSetNeedsDisplay = false
    link.preferredFrameLatency = 1
    let fps = Float(framesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
    link.delegate = self
    view.metrics.label("renderScheduling", "CAMetalDisplayLink")
    view.metrics.label("frameSelection", "newest from display-link drawable")
    view.metrics.label("displayLinkPreferredFrameLatency", "1")
    view.metrics.label("renderRequestedFPS", String(framesPerSecond))
    // Supplied drawables: neither MTKView acquisition nor the off-main worker.
    view.metrics.label("drawableAcquisitionPath", "CAMetalDisplayLink supplied drawable")
    link.add(to: .main, forMode: .common)
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    guard let view else { return }
    let now = CACurrentMediaTime()
    view.metrics.event("displayLinkCallbackInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    if update.targetTimestamp < now {
      view.metrics.increment("displayLinkMissedSubmissionDeadlines")
    } else {
      view.metrics.observe("displayLinkSubmissionDeadlineLead", milliseconds: (update.targetTimestamp - now) * 1000)
    }
    if update.targetPresentationTimestamp < now {
      view.metrics.increment("displayLinkLateCallbacks")
    } else {
      view.metrics.observe(
        "displayLinkTargetPresentationLead", milliseconds: (update.targetPresentationTimestamp - now) * 1000)
    }
    view.draw(displayLinkDrawable: update.drawable)
  }

  func stop() {
    link.isPaused = true
    link.delegate = nil
    link.invalidate()
  }
}
