#if os(macOS)
  import QuartzCore

  /// The drawable a display link offered for its next refresh. It stays usable until half the time to that refresh
  /// is gone (moonlight-qt's `renderLatestFrameOnDrawable`), so a frame that arrives in that window still makes it.
  struct ScreenSharingOfferedDrawable<Drawable> {
    private var held: (drawable: Drawable, deadline: Double)?

    mutating func offer(_ drawable: Drawable, now: Double, target: Double) {
      held = (drawable, now + max(0, target - now) / 2)
    }

    mutating func drawable(at now: Double) -> Drawable? {
      guard let held, now <= held.deadline else {
        held = nil
        return nil
      }
      return held.drawable
    }

    mutating func release() { held = nil }
  }

  @MainActor
  final class ScreenSharingDisplayLink: NSObject, CAMetalDisplayLinkDelegate {
    private var link: CAMetalDisplayLink?
    private let onUpdate: @MainActor (CAMetalDisplayLink.Update) -> Void

    init(layer: CAMetalLayer, framesPerSecond: Int, onUpdate: @escaping @MainActor (CAMetalDisplayLink.Update) -> Void)
    {
      self.onUpdate = onUpdate
      super.init()
      let link = CAMetalDisplayLink(metalLayer: layer)
      link.preferredFrameLatency = 1
      link.delegate = self
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

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
      // The link runs on the main run loop (see init), so the update never leaves the main thread.
      nonisolated(unsafe) let update = update
      MainActor.assumeIsolated { onUpdate(update) }
    }
  }
#endif
