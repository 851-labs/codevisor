#if os(macOS)
  import AppKit
  import Metal

  @MainActor
  public final class ScreenSharingMirrorView: NSView {
    public var onPresented: (() -> Void)? {
      didSet { metal.onPresented = onPresented.map { presented in { _ in presented() } } }
    }
    public var onStop: (() -> Void)?
    private let metal: ScreenSharingMetalView
    private var stopped = false
    private var letterboxColor = NSColor.windowBackgroundColor

    public init(mailbox: ScreenSharingFrameMailbox) throws {
      metal = try ScreenSharingMetalView(mailbox: mailbox, metrics: ScreenSharingMetrics(), renderOnArrival: true)
      super.init(frame: .zero)
      addSubview(metal)
    }

    public required init?(coder: NSCoder) { nil }

    public func setLetterboxColor(_ color: NSColor) {
      letterboxColor = color
      applyLetterboxColor()
    }

    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      applyLetterboxColor()
    }

    private func applyLetterboxColor() {
      var resolved: NSColor?
      effectiveAppearance.performAsCurrentDrawingAppearance { resolved = letterboxColor.usingColorSpace(.sRGB) }
      guard let color = resolved else { return }
      let alpha = Double(color.alphaComponent)
      metal.layer?.isOpaque = alpha >= 1
      metal.clearColor = MTLClearColorMake(
        Double(color.redComponent) * alpha, Double(color.greenComponent) * alpha, Double(color.blueComponent) * alpha,
        alpha)
      metal.needsDisplay = true
    }

    public override func layout() {
      super.layout()
      metal.frame = bounds
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func stop() {
      guard !stopped else { return }
      stopped = true
      metal.stop()
      onStop?()
      onStop = nil
    }
  }
#endif
