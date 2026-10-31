#if os(macOS)
  import AppKit
  import QuartzCore
  import ScreenSharing

  @MainActor
  public final class ScreenSharingV2DisplayLinkView: NSView {
    private let metalLayer = CAMetalLayer()
    private let compositor: ScreenSharingV2Compositor
    private var running = false
    private var stopped = false

    public init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
      compositor = try ScreenSharingV2Compositor(layer: metalLayer, mailbox: mailbox, metrics: metrics)
      super.init(frame: .zero)
      wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    public override func makeBackingLayer() -> CALayer { metalLayer }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !running, !stopped else { return }

      running = true
      compositor.start(framesPerSecond: Float(window.screen?.maximumFramesPerSecond ?? 60))
    }

    public override func layout() {
      super.layout()
      resizeDrawable()
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      resizeDrawable()
    }

    public func stop() {
      stopped = true
      compositor.stop()
    }

    private func resizeDrawable() {
      let scale = window?.backingScaleFactor ?? 1
      metalLayer.contentsScale = scale
      metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
      compositor.setNeedsRedraw()
    }
  }
#endif
