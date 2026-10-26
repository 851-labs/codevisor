import CoreVideo
import MetalKit

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
  public var isStopped: Bool { coordinator.stopped }
  package let coordinator: ScreenSharingRenderCoordinator
  private let encoder: ScreenSharingMetalEncoder
  private var preparer: (any ScreenSharingRenderPreparer)?
  #if os(macOS)
    private var offMainWorker: ScreenSharingMetalPreparer?
  #endif
  private let renderOnArrival: Bool

  public init(
    mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, renderOnArrival: Bool = false,
    maximumDrawableCount: Int = 3, offMainPreparation: Bool = false
  ) throws {
    guard (2...3).contains(maximumDrawableCount) else {
      throw ScreenSharingError.invalid("Drawable count must be two or three.")
    }
    #if !os(macOS)
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
    coordinator = ScreenSharingRenderCoordinator(
      mailbox: mailbox, metrics: metrics, renderOnArrival: renderOnArrival, redrawsOnDemand: offMainPreparation)
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: Self.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines)
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
      }
      if let workerEncoder {
        guard let metalLayer = layer as? CAMetalLayer else {
          throw ScreenSharingError.unavailable("The view has no Metal layer.")
        }
        let worker = ScreenSharingMetalPreparer(layer: metalLayer, encoder: workerEncoder, metrics: metrics)
        preparer = worker
        offMainWorker = worker
        autoResizeDrawable = false
      }
    #else
      isOpaque = true
      (layer as? CAMetalLayer)?.maximumDrawableCount = maximumDrawableCount
      _ = workerEncoder
    #endif
    metrics.label("maximumDrawableCount", String(maximumDrawableCount))
    metrics.label("frameSelection", "before drawable acquisition")
    metrics.label("renderPreparation", preparer == nil ? "main actor (MTKView)" : "off-main serial worker")
    metrics.label(
      "drawableAcquisitionPath",
      preparer == nil
        ? "MTKView.currentDrawable on main actor" : "CAMetalLayer.nextDrawable on render worker, default timeout")
    coordinator.bind { [weak self] in self?.draw() }
  }

  public func stop() {
    coordinator.stop()
    isPaused = true
  }

  required init(coder: NSCoder) { fatalError("Use init(mailbox:metrics:).") }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { coordinator.setNeedsRedraw() }

  public nonisolated static func drawRate(displayRefresh: Int) -> Int {
    guard displayRefresh > 60 else { return max(1, displayRefresh) }
    return displayRefresh / (displayRefresh / 60)
  }

  #if os(macOS)
    private var screenObserver: (any NSObjectProtocol)?
    private var screenParametersObserver: (any NSObjectProtocol)?

    public var onScreenHighDynamicRangeChanged: ((Bool) -> Void)? {
      didSet { reportedHighDynamicRange = nil; reportScreenHighDynamicRange() }
    }
    private var reportedHighDynamicRange: Bool?

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
      let size = backingDrawableSize
      guard size.width >= 1, size.height >= 1 else { metrics.increment("renderDeferredUntilLayout"); return }
      let clear = clearColor
      coordinator.prepare(
        with: preparer,
        geometry: .init(
          clearColor: SIMD4(clear.red, clear.green, clear.blue, clear.alpha), drawableSize: size))
    } else {
      renderFrame()
    }
  }

  private var backingDrawableSize: CGSize {
    #if os(macOS)
      let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1
      return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    #else
      return CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
    #endif
  }

  private func renderFrame() {
    guard !coordinator.stopped else { return }
    metrics.event("renderDriveInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
    guard let (frame, isNewFrame) = coordinator.select() else { return }
    guard let textures = encoder.textures(for: frame) else { metrics.increment("renderDrops"); return }
    showDynamicRange(textures.dynamicRange)
    guard let target = acquireSurface() else {
      metrics.increment("renderDrops")
      if isNewFrame { coordinator.deferPresentation() }
      return
    }
    coordinator.reportSize(ScreenSharingMetalEncoder.videoSize(of: frame))
    if target.drawable.texture.pixelFormat == ScreenSharingMetalEncoder.highDynamicRangePixelFormat {
      target.pass.colorAttachments[0].clearColor = Self.linear(clearColor)
    }
    guard let encoded = encoder.encode(textures, into: target) else {
      metrics.increment("renderDrops")
      if isNewFrame { coordinator.deferPresentation() }
      return
    }
    let submittedAt = CACurrentMediaTime()
    guard
      coordinator.commit(
        MetalSubmission(buffer: encoded.buffer, drawable: target.drawable, metrics: metrics),
        retaining: encoded.retained, frame: frame, isNewFrame: isNewFrame, submittedAt: submittedAt)
    else { metrics.increment("renderDrops"); return }
  }

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
        _ = handler
        metrics.label("presentationTelemetry", "unavailable in simulator")
      #endif
    }

    func commit() {
      buffer.present(drawable)
      buffer.commit()
    }
  }

  private var layerDynamicRange = ScreenSharingDynamicRange.standard

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
    nonisolated static func present(_ range: ScreenSharingDynamicRange, on metalLayer: CAMetalLayer) {
      metalLayer.preferredDynamicRange = range == .high ? .high : .standard
      metalLayer.toneMapMode = range == .high ? .never : .automatic
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

struct Surface {
  let drawable: any CAMetalDrawable
  let pass: MTLRenderPassDescriptor
}

final class TextureFrame: @unchecked Sendable {
  let frame: ScreenSharingVideoFrame
  let textures: [CVMetalTexture]
  init(frame: ScreenSharingVideoFrame, textures: [CVMetalTexture]) { self.frame = frame; self.textures = textures }
}

#if os(macOS)
  final class ScreenSharingMetalPreparer: ScreenSharingRenderPreparer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "codevisor.screen-sharing.render-worker", qos: .userInteractive)
    private let layer: CAMetalLayer
    private let encoder: ScreenSharingMetalEncoder
    private let metrics: ScreenSharingMetrics
    private var layerDynamicRange = ScreenSharingDynamicRange.standard

    init(layer: CAMetalLayer, encoder: ScreenSharingMetalEncoder, metrics: ScreenSharingMetrics) {
      self.layer = layer
      self.encoder = encoder
      self.metrics = metrics
    }

    func prepare(
      _ request: ScreenSharingPreparationRequest,
      completion: @escaping @Sendable (ScreenSharingPreparedSubmission?) -> Void
    ) {
      let encoder = encoder
      let metrics = metrics
      queue.async {
        let layer = self.layer
        let prepared: ScreenSharingPreparedSubmission? = autoreleasepool {
          let started = ScreenSharingMetrics.nowNs
          metrics.observe("renderPreparationQueueWait", milliseconds: Double(started - request.queuedAtNs) / 1_000_000)
          guard let textures = encoder.textures(for: request.frame) else { return nil }
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
          let drawable = layer.nextDrawable()
          let acquisitionEnded = ScreenSharingMetrics.nowNs
          metrics.observe(
            "drawableAcquisition", milliseconds: Double(acquisitionEnded - acquisitionStarted) / 1_000_000)
          guard let drawable else {
            metrics.increment("renderPreparationNoDrawable")
            return nil
          }
          let pass = MTLRenderPassDescriptor()
          pass.colorAttachments[0].texture = drawable.texture
          pass.colorAttachments[0].loadAction = .clear
          pass.colorAttachments[0].storeAction = .store
          let clear = request.geometry.clearColor
          let sRGB = MTLClearColor(red: clear.x, green: clear.y, blue: clear.z, alpha: clear.w)
          pass.colorAttachments[0].clearColor =
            drawable.texture.pixelFormat == ScreenSharingMetalEncoder.highDynamicRangePixelFormat
            ? ScreenSharingMetalView.linear(sRGB) : sRGB
          guard
            let encoded = encoder.encode(textures, into: Surface(drawable: drawable, pass: pass))
          else { return nil }
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
