import CoreVideo
import MetalKit

/// One queued frame and one GPU command buffer maximum. Biplanar YCbCr planes
/// (the decoder's output) and packed BGRA (a framebuffer backend's output) are
/// bound directly from the CVPixelBuffer through the texture cache.
/// Scheduling, caching and the stop boundary live in the coordinator; this
/// class encodes and submits (or, in the off-main diagnostic, hands the
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
  /// Diagnostic off-main preparation worker (nil = the ordinary MTKView path);
  /// assigned once after `super.init` because it needs the view's layer.
  private var preparer: (any ScreenSharingRenderPreparer)?
  #if os(macOS)
    private var offMainWorker: ScreenSharingMetalPreparer?
  #endif
  private let renderOnArrival: Bool

  /// `offMainPreparation` (diagnostic, macOS, requires `renderOnArrival`):
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
    preferredFramesPerSecond = 60
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
    metrics.label("renderPreparation", preparer == nil ? "main actor (MTKView)" : "off-main serial worker (diagnostic)")
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

  #if os(macOS)
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
      let size = convertToBacking(bounds).size
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

  private var backingDrawableSize: CGSize {
    #if os(macOS)
      convertToBacking(bounds).size
    #else
      CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
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

  private func acquireSurface() -> Surface? {
    let started = ScreenSharingMetrics.nowNs
    defer {
      metrics.observe("drawableAcquisition", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
    }
    guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor else { return nil }
    return Surface(drawable: drawable, pass: pass)
  }

  static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct ScreenVertex { float4 position [[position]]; float2 uv; };
    vertex ScreenVertex screenVertex(uint id [[vertex_id]]) {
      float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
      float2 p = positions[id];
      return {float4(p,0,1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    fragment float4 screenFragment(ScreenVertex in [[stage_in]],
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant float& fullRange [[buffer(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      float y = yPlane.sample(sample,in.uv).r;
      float2 uv = uvPlane.sample(sample,in.uv).rg - float2(128.0/255.0);
      if (fullRange < 0.5) { y = (y-16.0/255.0)*(255.0/219.0); uv *= 255.0/224.0; }
      return float4(y+1.5748*uv.y, y-0.187324*uv.x-0.468124*uv.y, y+1.8556*uv.x, 1);
    }
    fragment float4 screenFragmentBGRA(ScreenVertex in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      return float4(plane.sample(sample,in.uv).rgb, 1);
    }
    """
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

/// Pure Metal encoding of one frame into a surface — no actor, no AppKit.
/// One instance per thread (the texture cache is not shared); the command
/// queue and pipelines are shared (thread-safe / immutable per Metal).
struct ScreenSharingMetalEncoder: @unchecked Sendable {
  /// One pipeline per supported pixel layout, compiled once from the shared shader source.
  struct Pipelines: @unchecked Sendable {
    let biplanar: any MTLRenderPipelineState
    let bgra: any MTLRenderPipelineState

    init(device: any MTLDevice, shader: String) throws {
      let library = try device.makeLibrary(source: shader, options: nil)
      func pipeline(fragment: String) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
      }
      biplanar = try pipeline(fragment: "screenFragment")
      bgra = try pipeline(fragment: "screenFragmentBGRA")
    }
  }
  /// Validated plane textures of one frame, created before any drawable is acquired.
  struct Textures {
    enum Planes {
      /// 4:2:0 or 4:4:4 biplanar YCbCr, video or full range: the decoder's output.
      case biplanar(y: CVMetalTexture, uv: CVMetalTexture, fullRange: Bool)
      /// Packed 8-bit BGRA: a framebuffer backend's output, drawn without conversion.
      case bgra(CVMetalTexture)
    }
    let frame: ScreenSharingVideoFrame
    let planes: Planes
    var retained: [CVMetalTexture] {
      switch planes {
      case .biplanar(let y, let uv, _): [y, uv]
      case .bgra(let plane): [plane]
      }
    }
  }
  struct Encoded {
    let buffer: any MTLCommandBuffer
    let retained: TextureFrame
  }
  static let supportedPixelFormats: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_32BGRA,
  ]
  private let commandQueue: any MTLCommandQueue
  private let pipelines: Pipelines
  private let textureCache: CVMetalTextureCache

  init(device: any MTLDevice, commandQueue: any MTLCommandQueue, pipelines: Pipelines) throws {
    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard status == kCVReturnSuccess, let cache else { throw ScreenSharingError.codec("Create texture cache", status) }
    self.commandQueue = commandQueue
    self.pipelines = pipelines
    textureCache = cache
  }

  static func videoSize(of frame: ScreenSharingVideoFrame) -> CGSize {
    CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
  }

  /// The aspect-fit placement of one video inside a drawable: scaled to fit,
  /// centred, letterboxed on the short axis. Named so the letterbox geometry
  /// can be checked without a GPU drawable.
  static func viewport(video: CGSize, target: CGSize) -> MTLViewport {
    let scale = min(target.width / video.width, target.height / video.height)
    return MTLViewport(
      originX: (target.width - video.width * scale) / 2, originY: (target.height - video.height * scale) / 2,
      width: video.width * scale, height: video.height * scale, znear: 0, zfar: 1)
  }

  /// Pixel-format validation and plane textures; nil for an unsupported frame.
  func textures(for frame: ScreenSharingVideoFrame) -> Textures? {
    let pixel = frame.pixelBuffer
    let format = CVPixelBufferGetPixelFormatType(pixel)
    guard Self.supportedPixelFormats.contains(format) else { return nil }
    if format == kCVPixelFormatType_32BGRA {
      guard let plane = texture(pixel, plane: 0, format: .bgra8Unorm) else { return nil }
      return Textures(frame: frame, planes: .bgra(plane))
    }
    guard let y = texture(pixel, plane: 0, format: .r8Unorm), let uv = texture(pixel, plane: 1, format: .rg8Unorm)
    else { return nil }
    let fullRange = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange]
      .contains(format)
    return Textures(frame: frame, planes: .biplanar(y: y, uv: uv, fullRange: fullRange))
  }

  /// Encodes and ends encoding; the buffer is neither presented nor committed here.
  /// The video is scaled to fit the target and centred, letterboxed on the short axis.
  func encode(_ textures: Textures, into target: Surface) -> Encoded? {
    encode(textures, into: target.pass, target: target.drawable.texture)
  }

  /// The same drawing against a plain render target. A drawable contributes
  /// only its texture here, so the rendered pixels can be checked against an
  /// ordinary off-screen texture, with no CoreAnimation layer to acquire and
  /// no window server session to depend on.
  func encode(
    _ textures: Textures, into pass: MTLRenderPassDescriptor, target targetTexture: any MTLTexture
  ) -> Encoded? {
    guard
      let buffer = commandQueue.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { return nil }
    let pixel = textures.frame.pixelBuffer
    let video = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
    let targetSize = CGSize(width: targetTexture.width, height: targetTexture.height)
    encoder.setViewport(Self.viewport(video: video, target: targetSize))
    switch textures.planes {
    case .biplanar(let y, let uv, let isFullRange):
      guard let yTexture = CVMetalTextureGetTexture(y), let uvTexture = CVMetalTextureGetTexture(uv) else {
        encoder.endEncoding()
        return nil
      }
      encoder.setRenderPipelineState(pipelines.biplanar)
      encoder.setFragmentTexture(yTexture, index: 0)
      encoder.setFragmentTexture(uvTexture, index: 1)
      var fullRange: Float = isFullRange ? 1 : 0
      encoder.setFragmentBytes(&fullRange, length: MemoryLayout<Float>.size, index: 0)
    case .bgra(let plane):
      guard let planeTexture = CVMetalTextureGetTexture(plane) else {
        encoder.endEncoding()
        return nil
      }
      encoder.setRenderPipelineState(pipelines.bgra)
      encoder.setFragmentTexture(planeTexture, index: 0)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    return Encoded(buffer: buffer, retained: TextureFrame(frame: textures.frame, textures: textures.retained))
  }

  private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
      CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
    return status == kCVReturnSuccess ? texture : nil
  }
}

#if os(macOS)
  /// Diagnostic off-main preparation. A dedicated serial worker acquires from
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
      let layer = layer
      let encoder = encoder
      let metrics = metrics
      let audit = request.isNewFrame ? audit : nil
      let identity = request.auditIdentity
      let rtp = request.frame.rtpTimestamp
      queue.async {
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
          pass.colorAttachments[0].clearColor = MTLClearColor(
            red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
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
