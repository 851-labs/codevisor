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

    public init(mailbox: ScreenSharingFrameMailbox) throws {
      metal = try ScreenSharingMetalView(mailbox: mailbox, metrics: ScreenSharingMetrics(), renderOnArrival: true)
      super.init(frame: .zero)
      addSubview(metal)
    }

    public required init?(coder: NSCoder) { nil }

    public func setLetterboxColor(_ color: NSColor) {
      guard let resolved = color.usingColorSpace(.sRGB) else { return }
      metal.clearColor = MTLClearColorMake(
        Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent), 1)
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
