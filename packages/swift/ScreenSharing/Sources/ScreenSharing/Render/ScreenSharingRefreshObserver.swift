#if os(macOS)
  import AppKit
  import QuartzCore

  @MainActor
  final class ScreenSharingRefreshObserver: NSObject {
    private let timeline: ScreenSharingFrameTimeline
    private var link: CADisplayLink?

    init(view: NSView, timeline: ScreenSharingFrameTimeline, framesPerSecond: Int) {
      self.timeline = timeline
      super.init()
      let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
      follow(framesPerSecond: framesPerSecond)
    }

    func follow(framesPerSecond: Int) {
      let rate = Float(framesPerSecond)
      link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    func invalidate() {
      link?.invalidate()
      link = nil
    }

    @objc private func refresh(_ link: CADisplayLink) {
      timeline.observeRefresh(
        targetNs: ScreenSharingFramePresentation.nanoseconds(link.targetTimestamp),
        periodNs: ScreenSharingFramePresentation.nanoseconds(link.targetTimestamp - link.timestamp))
    }
  }
#endif
