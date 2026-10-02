import CoreVideo
import MetalKit

/// One queued frame and one GPU command buffer maximum. Biplanar YCbCr planes
/// (the decoder's output) and packed BGRA (a framebuffer backend's output) are
/// bound directly from the CVPixelBuffer through the texture cache.
/// Scheduling, caching and the stop boundary live in the coordinator; this
/// class encodes and submits (or, on the off-main path the product panes use, hands the
/// selected frame to a worker and commits its result).
@MainActor
public final class ScreenSharingMetalView: MTKView, MTKViewDelegate {
  public let mailbox: ScreenSharingFrameMailbox
  public let metrics: ScreenSharingMetrics
  public var onFrameSize: ((CGSize) -> Void)? {
    get { coordinator.onFrameSize }
    set { coordinator.onFrameSize = newValue }
  }
  public var onPresented: ((UInt32) -> Void)? {
    get { coordinator.onPresented }
    set { coordinator.onPresented = newValue }
  }
  /// Diagnostic: every on-screen presentation with its clocks and content identity. Nil costs nothing.
  public var onFramePresented: ((ScreenSharingPresentedFrame) -> Void)? {
    get { coordinator.onFramePresented }
    set { coordinator.onFramePresented = newValue }
  }
  /// True after `stop()`; nothing is scheduled, cached or notified afterwards.
  public var isStopped: Bool { coordinator.stopped }
  package let coordinator: ScreenSharingRenderCoordinator
  private let encoder: ScreenSharingMetalEncoder
  /// Off-main preparation worker (nil = the main-actor MTKView path);
  /// assigned once after `super.init` because it needs the view's layer.
  private var preparer: (any ScreenSharingRenderPreparer)?
  #if os(macOS)
    private var offMainWorker: ScreenSharingMetalPreparer?
  #endif
  private let renderOnArrival: Bool

  /// `offMainPreparation` (the product panes' path, macOS, requires `renderOnArrival`):
  /// drawable acquisition (`CAMetalLayer.nextDrawable`, default 1 s timeout
  /// kept) and command encoding run on a dedicated serial worker; selection,
  /// the single slot, commit and every product callback stay on the main actor.
  public init(
    mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, renderOnArrival: Bool = false,
    maximumDrawableCount: Int = 3, unsyncedPresentation: Bool = false, offMainPreparation: Bool = false,
    deliveryAudit: ScreenSharingFrameDeliveryAudit? = nil
  ) throws {
    guard (2...3).contains(maximumDrawableCount) else {
      throw ScreenSharingError.invalid("Drawable count must be two or three.")
    }
    #if !os(macOS)
      guard !unsyncedPresentation else { throw ScreenSharingError.invalid("Unsynced presentation requires macOS.") }
      guard !offMainPreparation else { throw ScreenSharingError.invalid("Off-main preparation requires macOS.") }
    #endif
    guard !offMainPreparation || renderOnArrival else {
      throw ScreenSharingError.invalid("Off-main preparation requires arrival-driven rendering.")
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw ScreenSharingError.unavailable("Metal is unavailable.")
    }
    self.mailbox = mailbox
    self.metrics = metrics
    self.renderOnArrival = renderOnArrival
    let coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: metrics, renderOnArrival: renderOnArrival, redrawsOnDemand: offMainPreparation)
    coordinator.audit = deliveryAudit
    self.coordinator = coordinator
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: Self.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines)
    // The worker owns its own texture cache; the command queue is shared (thread-safe per Metal).
    let workerEncoder: ScreenSharingMetalEncoder? =
      offMainPreparation
      ? try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines) : nil
    preparer = nil
    super.init(frame: .zero, device: device)
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColorMake(0.025, 0.025, 0.025, 1)
    preferredFramesPerSecond = Self.drawRate(displayRefresh: 60)
    framebufferOnly = true
    isPaused = renderOnArrival
    enableSetNeedsDisplay = renderOnArrival
    delegate = self
    #if os(macOS)
      wantsLayer = true
      layer?.isOpaque = true
      if let metalLayer = layer as? CAMetalLayer {
        metalLayer.maximumDrawableCount = maximumDrawableCount
        metalLayer.displaySyncEnabled = !unsyncedPresentation
      }
      if let workerEncoder {
        guard let metalLayer = layer as? CAMetalLayer else {
          throw ScreenSharingError.unavailable("The view has no Metal layer.")
        }
        let worker = ScreenSharingMetalPreparer(
          layer: metalLayer, encoder: workerEncoder, metrics: metrics, audit: deliveryAudit)
        preparer = worker
        offMainWorker = worker
        // The worker owns every layer mutation and acquisition in this mode: each
        // request carries the view's backing size as an immutable snapshot (no
        // lock the main actor could wait on), so MTKView's automatic resize is off.
        autoResizeDrawable = false
      }
    #else
      isOpaque = true
      (layer as? CAMetalLayer)?.maximumDrawableCount = maximumDrawableCount
      _ = workerEncoder
    #endif
    metrics.label("maximumDrawableCount", String(maximumDrawableCount))
    metrics.label("displaySync", unsyncedPresentation ? "disabled experiment" : "enabled")
    metrics.label("frameSelection", "before drawable acquisition")
    metrics.label("renderPreparation", preparer == nil ? "main actor (MTKView)" : "off-main serial worker")
    metrics.label(
      "drawableAcquisitionPath",
      preparer == nil
        ? "MTKView.currentDrawable on main actor" : "CAMetalLayer.nextDrawable on render worker, default timeout")
    coordinator.bind { [weak self] in self?.draw() }
  }

  /// Terminal, idempotent stop boundary (see `ScreenSharingRenderCoordinator.stop`).
  /// Pauses the display-link drive as well; a submission already in flight
  /// keeps its buffer and textures until the GPU completes it, and a
  /// preparation already on the worker finishes or times out on its own.
  public func stop() {
    coordinator.stop()
    isPaused = true
  }

  required init(coder: NSCoder) { fatalError("Use init(mailbox:metrics:).") }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { coordinator.setNeedsRedraw() }

  /// The draw rate for a display refreshing `displayRefresh` times a second (851-2374). The
  /// display link can only run at whole fractions of the refresh, so asking for 60 on a 72 Hz
  /// display got 36: the "30 fps ceiling" every native session had on such a display. This is the
  /// smallest whole fraction that still reaches 60 (72 at 72 Hz, 60 at 120 Hz, 72 at 144 Hz), or
  /// the refresh itself on a display slower than 60 Hz.
  public nonisolated static func drawRate(displayRefresh: Int) -> Int {
    guard displayRefresh > 60 else { return max(1, displayRefresh) }
    return displayRefresh / (displayRefresh / 60)
  }

  #if os(macOS)
    private var screenObserver: (any NSObjectProtocol)?
    private var screenParametersObserver: (any NSObjectProtocol)?

    /// Whether the screen the window is on can show high dynamic range (851-2380): reported when
    /// the view joins a window, and again when the window moves to another screen or the screen's
    /// settings change (an HDR display preset turned off, a display attached).
    public var onScreenHighDynamicRangeChanged: ((Bool) -> Void)? {
      didSet { reportedHighDynamicRange = nil; reportScreenHighDynamicRange() }
    }
    private var reportedHighDynamicRange: Bool?

    /// Follows the refresh and dynamic range of whatever screen the window is on.
    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      for observer in [screenObserver, screenParametersObserver].compactMap({ $0 }) {
        NotificationCenter.default.removeObserver(observer)
      }
      screenObserver = nil
      screenParametersObserver = nil
      guard let window else { return }
      matchDisplayRefresh()
      reportScreenHighDynamicRange()
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.matchDisplayRefresh()
          self?.reportScreenHighDynamicRange()
        }
      }
      screenParametersObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.reportScreenHighDynamicRange() } }
    }

    private func reportScreenHighDynamicRange() {
      guard let screen = window?.screen else { return }
      let supported = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
      guard supported != reportedHighDynamicRange else { return }
      reportedHighDynamicRange = supported
      onScreenHighDynamicRangeChanged?(supported)
    }

    private func matchDisplayRefresh() {
      guard let refresh = window?.screen?.maximumFramesPerSecond, refresh > 0 else { return }
      let rate = Self.drawRate(displayRefresh: refresh)
      guard rate != preferredFramesPerSecond else { return }
      preferredFramesPerSecond = rate
      metrics.label("drawRate", "\(rate) per second on a \(refresh) Hz display")
    }

    public override func layout() {
      super.layout()
      resizeDrawableOffMain()
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      resizeDrawableOffMain()
    }

    /// Off-main mode only (MTKView auto-resize is off there): a resize or
    /// backing-scale change asks the coordinator for a redraw of the cached
    /// frame; the draw is scheduled (never reentrant here) and its request
    /// carries the new backing size, which the worker applies before acquiring.
    private func resizeDrawableOffMain() {
      guard offMainWorker != nil else { return }
      let size = backingDrawableSize
      guard size.width >= 1, size.height >= 1 else { return }
      coordinator.setNeedsRedraw()
    }
  #endif

  public func draw(in view: MTKView) {
    if let preparer {
      guard !coordinator.stopped else { return }
      metrics.event("renderDriveInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
      // Seeded from the view's current backing size; before the first layout the
      // frame stays in the mailbox and the resize-driven redraw picks it up.
      let size = backingDrawableSize
      guard size.width >= 1, size.height >= 1 else { metrics.increment("renderDeferredUntilLayout"); return }
      let clear = clearColor
      coordinator.prepare(
        with: preparer,
        geometry: .init(
          clearColor: SIMD4(clear.red, clear.green, clear.blue, clear.alpha), drawableSize: size))
    } else {
      renderFrame(surface: nil)
    }
  }

  /// The view's own bounds in pixels. Not `convertToBacking(bounds)`: that maps through the
  /// window, so a rotated view (a simulator held sideways) would get its turned bounding box and
  /// draw the video squeezed into the swapped size.
  private var backingDrawableSize: CGSize {
    #if os(macOS)
      let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1
      return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    #else
      return CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
    #endif
  }

  /// The standalone Metal display-link experiment supplies its drawable. The
  /// ordinary MTKView path retains its existing acquisition/scheduling policy.
  public func draw(displayLinkDrawable drawable: any CAMetalDrawable) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = clearColor
    renderFrame(surface: Surface(drawable: drawable, pass: pass))
  }

  /// The ordinary main-actor path, in the Stage 3g order: select → validate the
  /// pixel format and create the plane textures → acquire the MTKView drawable
  /// (as late as possible) → encode → commit. The submission clock starts in
  /// the coordinator at final submission, not during acquisition.
  private func renderFrame(surface: Surface?) {
    guard !coordinator.stopped else { return }
    metrics.event("renderDriveInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    guard let (frame, isNewFrame) = coordinator.select() else { return }
    let audit = isNewFrame ? coordinator.audit : nil
    guard let textures = encoder.textures(for: frame) else { metrics.increment("renderDrops"); return }
    if surface == nil { showDynamicRange(textures.dynamicRange) }
    // The acquisition pair brackets only the actual MTKView acquisition; a
    // supplied drawable (display-link experiment) records no acquisition.
    let target: Surface?
    if let surface {
      target = surface
    } else {
      if let audit { audit.record(.acquisitionBegin, frame.deliveryAuditIdentity, rtpTimestamp: frame.rtpTimestamp) }
      target = acquireSurface()
      if let audit {
        audit.record(
          .acquisitionEnd, frame.deliveryAuditIdentity, rtpTimestamp: frame.rtpTimestamp, valueNs: target == nil ? 0 : 1
        )
      }
    }
    guard let target else {
      metrics.increment("renderDrops")
      if isNewFrame { coordinator.deferPresentation() }
      return
    }
    coordinator.reportSize(ScreenSharingMetalEncoder.videoSize(of: frame))
    // The letterbox colour is sRGB; a linear HDR drawable needs it linear, or the bars turn grey.
    if target.drawable.texture.pixelFormat == ScreenSharingMetalEncoder.highDynamicRangePixelFormat {
      target.pass.colorAttachments[0].clearColor = Self.linear(clearColor)
    }
    guard let encoded = encoder.encode(textures, into: target) else {
      metrics.increment("renderDrops")
      if isNewFrame { coordinator.deferPresentation() }
      return
    }
    // Submission boundary after successful encoding, immediately before commit —
    // the same boundary the off-main worker's result uses.
    let submittedAt = CACurrentMediaTime()
    // Refused after a stop that happened during encoding (e.g. inside the
    // size callback): the encoded buffer is never committed or presented.
    guard
      coordinator.commit(
        MetalSubmission(buffer: encoded.buffer, drawable: target.drawable, metrics: metrics),
        retaining: encoded.retained, frame: frame, isNewFrame: isNewFrame, submittedAt: submittedAt)
    else { metrics.increment("renderDrops"); return }
  }

  /// The real submission: command-buffer completion and drawable presentation.
  /// Metal/CA objects are handed between threads by design (Metal documents
  /// the command queue as thread-safe and one thread per command buffer).
  struct MetalSubmission: ScreenSharingRenderSubmission, @unchecked Sendable {
    let buffer: any MTLCommandBuffer
    let drawable: any CAMetalDrawable
    let metrics: ScreenSharingMetrics

    func onCompleted(_ handler: @escaping @Sendable (Bool) -> Void) {
      buffer.addCompletedHandler { command in handler(command.status == .completed) }
    }

    func onPresented(_ handler: @escaping @Sendable (Double) -> Void) {
      #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { presented in handler(presented.presentedTime) }
      #else
        // Simulator Metal has no drawable presentation callback. GPU completion
        // remains observable, but it must not be reported as physical presentation.
        _ = handler
        metrics.label("presentationTelemetry", "unavailable in simulator")
      #endif
    }

    func commit() {
      buffer.present(drawable)
      buffer.commit()
    }
  }

  /// The dynamic range the layer shows. HDR frames (851-2380) switch it to half-float extended-linear
  /// Display P3 with extended dynamic range: SDR white is 1.0, so the host's windows are exactly as
  /// bright as in SDR, and highlights go above it up to this display's headroom. SDR frames switch
  /// it back. Before the first drawable of the new range is acquired, so no frame
  /// is drawn in the wrong format.
  private var layerDynamicRange = ScreenSharingDynamicRange.standard

  /// An sRGB-encoded colour as linear light (the IEC 61966-2-1 curve), alpha unchanged.
  nonisolated static func linear(_ color: MTLClearColor) -> MTLClearColor {
    func channel(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return MTLClearColor(
      red: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: color.alpha)
  }

  private func showDynamicRange(_ range: ScreenSharingDynamicRange) {
    guard range != layerDynamicRange else { return }
    layerDynamicRange = range
    colorPixelFormat = range == .high ? ScreenSharingMetalEncoder.highDynamicRangePixelFormat : .bgra8Unorm
    #if os(macOS)
      if let metalLayer = layer as? CAMetalLayer { Self.present(range, on: metalLayer) }
    #endif
    metrics.label("renderDynamicRange", range.rawValue)
  }

  #if os(macOS)
    /// The layer's presentation of a dynamic range, besides its pixel format. Shared by the main
    /// path and the render worker, which applies it on its own queue before acquiring.
    nonisolated static func present(_ range: ScreenSharingDynamicRange, on metalLayer: CAMetalLayer) {
      // Extended range without tone mapping: automatic tone mapping squeezed each whole frame into
      // the display's current headroom whenever it held a highlight, and took SDR white down with it
      // (to ~58% at night brightness, tuftlord → M4 Max, 2026-09-30). Unmapped, 1.0 stays this Mac's
      // white and only highlights past the headroom clip.
      metalLayer.preferredDynamicRange = range == .high ? .high : .standard
      metalLayer.toneMapMode = range == .high ? .never : .automatic
      // Not a PQ layer with HDR10 metadata: macOS tone-maps that whole curve into the display's
      // current headroom, which pulled SDR white down to 40% on a MacBook Pro at night (tuftlord →
      // M4 Max, 2026-09-30). The shader places the host's SDR white at 1.0 itself.
      metalLayer.colorspace = range == .high ? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) : nil
    }
  #endif

  private func acquireSurface() -> Surface? {
    let started = ScreenSharingMetrics.nowNs
    defer {
      metrics.observe("drawableAcquisition", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    }
    guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor else { return nil }
    return Surface(drawable: drawable, pass: pass)
  }
}

/// A drawable with its render pass (MTKView's on the main actor, or one built
/// by the off-main worker from `CAMetalLayer.nextDrawable`).
struct Surface {
  let drawable: any CAMetalDrawable
  let pass: MTLRenderPassDescriptor
}

/// Pixel buffer + its CVMetalTextures, held until actual GPU completion so the
/// IOSurface storage stays alive throughout GPU reads.
final class TextureFrame: @unchecked Sendable {
  let frame: ScreenSharingVideoFrame
  let textures: [CVMetalTexture]
  init(frame: ScreenSharingVideoFrame, textures: [CVMetalTexture]) { self.frame = frame; self.textures = textures }
}

#if os(macOS)
  /// Off-main preparation (the product panes' renderer). A dedicated serial worker acquires from
  /// `CAMetalLayer.nextDrawable` (the layer's default 1 s timeout is kept —
  /// `allowsNextDrawableTimeout` is never disabled), builds the render pass
  /// and encodes; the result goes back to the coordinator, which alone commits.
  /// At most one preparation is outstanding (the coordinator's slot); an
  /// acquisition already blocking when the renderer stops finishes or times
  /// out on its own, touches no AppKit state, and its result is dropped.
  final class ScreenSharingMetalPreparer: ScreenSharingRenderPreparer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "codevisor.screen-sharing.render-worker", qos: .userInteractive)
    private let layer: CAMetalLayer
    private let encoder: ScreenSharingMetalEncoder
    private let metrics: ScreenSharingMetrics
    private let audit: ScreenSharingFrameDeliveryAudit?
    /// What the layer is set up to show; read and written only on `queue`.
    private var layerDynamicRange = ScreenSharingDynamicRange.standard

    init(
      layer: CAMetalLayer, encoder: ScreenSharingMetalEncoder, metrics: ScreenSharingMetrics,
      audit: ScreenSharingFrameDeliveryAudit? = nil
    ) {
      self.layer = layer
      self.encoder = encoder
      self.metrics = metrics
      self.audit = audit
    }

    func prepare(
      _ request: ScreenSharingPreparationRequest,
      completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
    ) {
      let encoder = encoder
      let metrics = metrics
      let audit = request.isNewFrame ? audit : nil
      let identity = request.auditIdentity
      let rtp = request.frame.rtpTimestamp
      queue.async {
        // The layer is not Sendable; it is only touched on this queue, which is the
        // confinement this class's `@unchecked Sendable` stands for.
        let layer = self.layer
        // One autorelease-pool boundary per preparation: a drawable or texture
        // that is not handed back is released here, never at a later drain.
        let prepared: ScreenSharingPreparedSubmission? = autoreleasepool {
          let started = ScreenSharingMetrics.nowNs
          if let audit { audit.record(.preparationBegin, identity, rtpTimestamp: rtp, atNs: audit.now()) }
          metrics.observe("renderPreparationQueueWait", milliseconds: Double(started - request.queuedAtNs) / 1_000_000)
          // Textures first (as on the main path), then the layer size from the
          // request's snapshot — the only layer mutation, on this queue — then the
          // acquisition, as late as possible.
          guard let textures = encoder.textures(for: request.frame) else { return nil }
          // HDR frames (851-2380) switch the layer to half-float extended-linear Display P3, SDR
          // frames back; before the drawable of the new range is acquired, as on the main path.
          let range = textures.dynamicRange
          if range != self.layerDynamicRange {
            self.layerDynamicRange = range
            layer.pixelFormat = range == .high ? ScreenSharingMetalEncoder.highDynamicRangePixelFormat : .bgra8Unorm
            ScreenSharingMetalView.present(range, on: layer)
            metrics.label("renderDynamicRange", range.rawValue)
          }
          if layer.drawableSize != request.geometry.drawableSize {
            layer.drawableSize = request.geometry.drawableSize
            metrics.increment("drawableSizeUpdatesOnWorker")
          }
          let acquisitionStarted = ScreenSharingMetrics.nowNs
          if let audit { audit.record(.acquisitionBegin, identity, rtpTimestamp: rtp, atNs: audit.now()) }
          let drawable = layer.nextDrawable()  // blocks at most the layer's default 1 s timeout
          let acquisitionEnded = ScreenSharingMetrics.nowNs
          if let audit {
            audit.record(
              .acquisitionEnd, identity, rtpTimestamp: rtp, valueNs: drawable == nil ? 0 : 1, atNs: audit.now())
          }
          metrics.observe(
            "drawableAcquisition", milliseconds: Double(acquisitionEnded - acquisitionStarted) / 1_000_000)
          guard let drawable else {
            // nil = timeout OR invalid layer properties; the layer does not say which.
            metrics.increment("renderPreparationNoDrawable")
            return nil
          }
          let pass = MTLRenderPassDescriptor()
          pass.colorAttachments[0].texture = drawable.texture
          pass.colorAttachments[0].loadAction = .clear
          pass.colorAttachments[0].storeAction = .store
          let clear = request.geometry.clearColor
          let sRGB = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
          // The letterbox colour is sRGB; a linear HDR drawable needs it linear, or the bars turn grey.
          pass.colorAttachments[0].clearColor =
            drawable.texture.pixelFormat == ScreenSharingMetalEncoder.highDynamicRangePixelFormat
            ? ScreenSharingMetalView.linear(sRGB) : sRGB
          guard
            let encoded = encoder.encode(textures, into: Surface(drawable: drawable, pass: pass))
          else { return nil }  // the drawable is released with this pool, never presented
          metrics.observe("renderPreparation", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
          return .init(
            submission: ScreenSharingMetalView.MetalSubmission(
              buffer: encoded.buffer, drawable: drawable, metrics: metrics),
            retained: encoded.retained, videoSize: ScreenSharingMetalEncoder.videoSize(of: request.frame))
        }
        completion(prepared)
      }
    }
  }
#endif
