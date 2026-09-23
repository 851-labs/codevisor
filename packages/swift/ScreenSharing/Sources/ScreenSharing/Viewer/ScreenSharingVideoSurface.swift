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
    /// The remote pointer when the backend reports it (VNC Cursor/PointerPos,
    /// 851-2311): its shape is the local cursor while controlling, so the
    /// pointer moves without a network round trip; while viewing, an overlay
    /// shows it where the host put it. Without a shape the remote draws its own
    /// pointer into the video and the local one is hidden, as before.
    private var remoteShape: RFBCursorShape?
    private var remoteImage: CGImage?
    private var remotePosition: RFBPoint?
    private var shapedCursor: NSCursor?
    private let cursorOverlay = ScreenSharingCursorOverlay()
    /// What the pointer looks like over the video while controlling.
    var controlCursor: NSCursor { shapedCursor ?? Self.remoteCursor }
    /// Whether the view-mode overlay is showing, and where (for tests).
    var remoteCursorOverlayFrame: CGRect? { cursorOverlay.isHidden ? nil : cursorOverlay.frame }
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
      cursorOverlay.isHidden = true
      addSubview(cursorOverlay)
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
    /// The size in points and the backing scale, reported when either changes
    /// (851-2314; the scale for a Retina remote desktop, 851-2315).
    public var onSizeChanged: ((CGSize, CGFloat) -> Void)? {
      didSet { reported = nil; reportSize() }
    }
    private var reported: (size: CGSize, scale: CGFloat)?
    private func reportSize() {
      let scale = window?.backingScaleFactor ?? 1
      guard bounds.width > 0, bounds.height > 0, reported?.size != bounds.size || reported?.scale != scale
      else { return }
      reported = (bounds.size, scale)
      onSizeChanged?(bounds.size, scale)
    }

    public override func layout() {
      super.layout()
      metal.frame = bounds
      reportSize()
      refreshRemoteCursor()
      window?.invalidateCursorRects(for: self)
    }

    public func showRemoteCursor(_ update: ScreenSharingCursorUpdate) {
      switch update {
      case .shape(let shape):
        remoteShape = shape.isHidden ? nil : shape
        remoteImage = remoteShape.flatMap(Self.image)
      case .position(let point):
        remotePosition = point
      }
      refreshRemoteCursor()
      window?.invalidateCursorRects(for: self)
    }

    /// Rebuilds the shaped cursor at the video's current on-screen scale and
    /// places (or hides) the view-mode overlay.
    private func refreshRemoteCursor() {
      let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
      if let shape = remoteShape, let image = remoteImage, scale.isFinite, scale > 0 {
        let cursor = CGFloat(
          ScreenSharingVideoGeometry.cursorScale(videoScale: Double(scale), cursorHeight: Double(shape.height)))
        let size = NSSize(width: CGFloat(shape.width) * cursor, height: CGFloat(shape.height) * cursor)
        shapedCursor = NSCursor(
          image: NSImage(cgImage: image, size: size),
          hotSpot: NSPoint(x: CGFloat(shape.hotspotX) * cursor, y: CGFloat(shape.hotspotY) * cursor))
      } else {
        shapedCursor = nil
      }
      guard !input.isLive, let shape = remoteShape, let image = remoteImage, let position = remotePosition,
        let frame = ScreenSharingVideoGeometry.cursorFrame(
          x: Double(position.x), y: Double(position.y), hotspotX: Double(shape.hotspotX),
          hotspotY: Double(shape.hotspotY), cursorWidth: Double(shape.width), cursorHeight: Double(shape.height),
          surfaceWidth: bounds.width, surfaceHeight: bounds.height, videoWidth: videoSize.width,
          videoHeight: videoSize.height)
      else {
        cursorOverlay.isHidden = true
        return
      }
      cursorOverlay.frame = CGRect(
        x: frame.x, y: isFlipped ? frame.y : bounds.height - frame.y - frame.height, width: frame.width,
        height: frame.height)
      cursorOverlay.layer?.contents = image
      cursorOverlay.isHidden = false
    }

    /// Premultiplied BGRA (the shape's layout) as a CGImage.
    static func image(_ shape: RFBCursorShape) -> CGImage? {
      guard let provider = CGDataProvider(data: Data(shape.pixels) as CFData) else { return nil }
      return CGImage(
        width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: shape.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
          .union(.byteOrder32Little),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      needsLayout = true
      reportSize()
    }
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
      guard input.isLive else { return }
      let drawable = metal.convertToBacking(metal.bounds).size
      let scale = min(drawable.width / videoSize.width, drawable.height / videoSize.height)
      let video = CGRect(
        x: (drawable.width - videoSize.width * scale) / 2,
        y: (drawable.height - videoSize.height * scale) / 2,
        width: videoSize.width * scale, height: videoSize.height * scale)
      let rect = convert(metal.convertFromBacking(video), from: metal).intersection(bounds)
      if !rect.isEmpty { addCursorRect(rect, cursor: controlCursor) }
    }
    func controlCursorChanged() {
      refreshRemoteCursor()
      window?.invalidateCursorRects(for: self)
      if !input.isLive, isControlCursor(NSCursor.current) { NSCursor.arrow.set() }
    }
    public override func cursorUpdate(with event: NSEvent) {
      if input.isLive, pointer(event, clamp: false) != nil { controlCursor.set() } else { NSCursor.arrow.set() }
    }
    public override func mouseExited(with event: NSEvent) {
      if isControlCursor(NSCursor.current) { NSCursor.arrow.set() }
    }
    private func isControlCursor(_ cursor: NSCursor?) -> Bool {
      cursor === Self.remoteCursor || (shapedCursor != nil && cursor === shapedCursor)
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

  /// The view-mode remote pointer: drawn over the video, never hit by the mouse.
  final class ScreenSharingCursorOverlay: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer?.contentsGravity = .resize
      layer?.magnificationFilter = .nearest
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif
