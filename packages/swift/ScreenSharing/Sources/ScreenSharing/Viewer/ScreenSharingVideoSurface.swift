#if os(macOS)
  import AppKit
  import ScreenSharing
  import Metal
  import OSLog

  @MainActor
  public final class ScreenSharingVideoSurface: NSView, ScreenSharingInputTarget, ScreenSharingViewerSurface {
    public var onFocusChanged: ((Bool) -> Void)?
    let metal: ScreenSharingMetalView
    lazy var input = ScreenSharingInputSurface(view: self)
    public var view: NSView { self }
    public var onPresented: (() -> Void)? {
      didSet { metal.onPresented = onPresented.map { presented in { _ in presented() } } }
    }
    public var onInput: ((ScreenSharingInputEvent) -> Void)? {
      get { input.onInput }
      set { input.onInput = newValue }
    }
    public var onInputReleased: (() -> Void)? {
      get { input.onRelease }
      set { input.onRelease = newValue }
    }
    public var inputFailureMessage: String? { input.failureMessage }
    public func setLetterboxColor(_ color: NSColor) { letterboxColor = color }
    public func beginInput() -> Bool { input.begin() }
    public func endInput() { input.end() }
    private var tracking: NSTrackingArea?
    private static let remoteCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private var videoSize = CGSize(width: 1920, height: 1080)
    /// The fill around the remote display: the letterbox bars an aspect-fit
    /// leaves, and the whole surface before the first frame. Apple's Screen
    /// Sharing seats the remote screen on the window surface rather than black
    /// bars, so the default is the dynamic window background, resolved against
    /// this view's appearance (the Metal clear color is a fixed value, so it is
    /// re-resolved whenever the appearance or the color changes). The pane
    /// passes its own surface color when a theme palette is active.
    public var letterboxColor: NSColor = .windowBackgroundColor { didSet { applyLetterboxColor() } }

    /// `profile` nil (the default) keeps the product renderer exactly as it was: display-link drive, three drawables,
    /// main-actor preparation. The explicit profile forwards to the EXISTING worker/arrival2 initializer; no pacing,
    /// render-queue rewrite or auditing feature is added here.
    public init(
      mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, profile: ScreenSharingDiagnosticProfile? = nil
    ) throws {
      metal = try ScreenSharingMetalView(
        mailbox: mailbox, metrics: metrics, renderOnArrival: profile?.renderOnArrival ?? false,
        maximumDrawableCount: profile?.maximumDrawableCount ?? 3,
        offMainPreparation: profile?.offMainPreparation ?? false)
      super.init(frame: .zero)
      addSubview(metal)
      metal.onFrameSize = { [weak self] size in
        self?.videoSize = size
        self?.needsLayout = true
      }
      applyLetterboxColor()
    }

    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      applyLetterboxColor()
    }

    /// Resolves `letterboxColor` for the current appearance into the renderer's
    /// clear color. A fully transparent color (a theme that defers to the
    /// window backdrop) falls back to the window background, because the Metal
    /// layer is opaque.
    private func applyLetterboxColor() {
      var resolved: NSColor?
      effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = letterboxColor.usingColorSpace(.sRGB)
        if (resolved?.alphaComponent ?? 0) <= 0 { resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) }
      }
      guard let color = resolved else { return }
      metal.clearColor = MTLClearColorMake(
        Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), 1)
      metal.needsDisplay = true
    }
    public required init?(coder: NSCoder) { nil }
    /// The video always fills the pane, scaled to fit and letterboxed by the renderer.
    public override func layout() {
      super.layout()
      metal.frame = bounds
      window?.invalidateCursorRects(for: self)
    }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    /// Input first, then the renderer's terminal stop (arrival subscription,
    /// mailbox, cached frame and callbacks released; an in-flight submission
    /// keeps its buffers until the GPU completes it).
    public func stop() { input.end(); metal.stop() }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted { input.resume(); onFocusChanged?(true) }
      return accepted
    }
    public override func resignFirstResponder() -> Bool {
      let accepted = super.resignFirstResponder()
      if accepted { input.suspend(); onFocusChanged?(false) }
      return accepted
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
      let hit = super.hitTest(point)
      return input.active && hit != nil ? self : hit
    }
    public override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      tracking = area; addTrackingArea(area)
    }
    public override func resetCursorRects() {
      super.resetCursorRects()
      guard input.active else { return }
      let drawable = metal.convertToBacking(metal.bounds).size
      let scale = min(drawable.width / videoSize.width, drawable.height / videoSize.height)
      let video = CGRect(
        x: (drawable.width - videoSize.width * scale) / 2,
        y: (drawable.height - videoSize.height * scale) / 2,
        width: videoSize.width * scale, height: videoSize.height * scale)
      let rect = convert(metal.convertFromBacking(video), from: metal).intersection(bounds)
      if !rect.isEmpty { addCursorRect(rect, cursor: Self.remoteCursor) }
    }
    func controlCursorChanged() {
      window?.invalidateCursorRects(for: self)
      if !input.active, NSCursor.current === Self.remoteCursor { NSCursor.arrow.set() }
    }
    public override func cursorUpdate(with event: NSEvent) {
      if input.active, pointer(event, clamp: false) != nil { Self.remoteCursor.set() } else { NSCursor.arrow.set() }
    }
    public override func mouseExited(with event: NSEvent) {
      if NSCursor.current === Self.remoteCursor { NSCursor.arrow.set() }
    }
    public override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    public override func mouseMoved(with event: NSEvent) {
      if input.active { cursorUpdate(with: event) }
      input.mouse(event)
    }
    public override func mouseDown(with event: NSEvent) { input.mouse(event) }
    public override func mouseUp(with event: NSEvent) { input.mouse(event) }
    public override func rightMouseDown(with event: NSEvent) { input.mouse(event) }
    public override func rightMouseUp(with event: NSEvent) { input.mouse(event) }
    public override func otherMouseDown(with event: NSEvent) { input.mouse(event) }
    public override func otherMouseUp(with event: NSEvent) { input.mouse(event) }
    public override func mouseDragged(with event: NSEvent) { input.mouse(event) }
    public override func rightMouseDragged(with event: NSEvent) { input.mouse(event) }
    public override func otherMouseDragged(with event: NSEvent) { input.mouse(event) }
    public override func scrollWheel(with event: NSEvent) {
      if input.active { input.mouse(event) } else { super.scrollWheel(with: event) }
    }
    func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer? {
      let point = metal.convertToBacking(metal.convert(event.locationInWindow, from: nil))
      let size = metal.convertToBacking(metal.bounds).size
      return ScreenSharingVideoGeometry.pointer(
        x: point.x, y: metal.isFlipped ? point.y : size.height - point.y,
        surfaceWidth: size.width, surfaceHeight: size.height,
        videoWidth: videoSize.width, videoHeight: videoSize.height, clamp: clamp)
    }

  }
#endif
