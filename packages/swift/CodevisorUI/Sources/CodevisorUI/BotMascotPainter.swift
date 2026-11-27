import Metal
import MetalPerformanceShaders
@preconcurrency import RiveRuntime

@MainActor
final class BotMascotPainter {
  static let device = MTLCreateSystemDefaultDevice()

  private let gate = BotMascotFrameGate()
  private let queue = device?.makeCommandQueue()
  private let scaler = device.map { MPSImageLanczosScale(device: $0) }
  private var renderer: (any RiveUIRendererProtocol)?
  private var canvas: (any MTLTexture)?

  func paint(_ rig: BotMascotRig, into views: [BotMascotCanvasView]) {
    let side = views.compactMap(\.drawableSide).max()
    guard let side, let device = Self.device, let queue, let scaler, gate.enter() else { return }

    let source = canvas(side: side, device: device)
    let targets = views.compactMap { view in view.nextDrawable().map { (view, $0) } }
    let copy = BotMascotFrameCopy(
      source: source, drawables: targets.map(\.1), scaler: scaler, onShown: Self.reportShown(targets.map(\.0)))
    renderer(for: rig).draw(
      rig.configuration(drawableSize: CGSize(width: side, height: side)),
      to: source,
      from: device,
      onDraw: copy.finishing(gate),
      onSkipped: copy.resending(on: queue, then: gate),
      onError: copy.abandoning(gate)
    )
  }

  private static func reportShown(_ views: [BotMascotCanvasView]) -> @Sendable () -> Void {
    let shown = BotMascotShownViews(views)
    return { Task { @MainActor in shown.views.forEach { $0?.showedFrame() } } }
  }

  private func renderer(for rig: BotMascotRig) -> any RiveUIRendererProtocol {
    if let renderer { return renderer }

    let renderer = rig.rive.makeRenderer()
    self.renderer = renderer
    return renderer
  }

  private func canvas(side: Int, device: any MTLDevice) -> any MTLTexture {
    if let canvas, canvas.width == side { return canvas }

    let canvas = Self.makeCanvas(side: side, device: device)
    self.canvas = canvas
    return canvas
  }

  private static func makeCanvas(side: Int, device: any MTLDevice) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: MTLRiveColorPixelFormat(), width: side, height: side, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      preconditionFailure("Metal couldn't allocate a \(side)px mascot canvas")
    }
    return texture
  }
}

private final class BotMascotShownViews: @unchecked Sendable {
  private let references: [WeakReference]

  @MainActor
  init(_ views: [BotMascotCanvasView]) {
    references = views.map(WeakReference.init)
  }

  @MainActor
  var views: [BotMascotCanvasView?] { references.map(\.view) }

  private final class WeakReference {
    weak var view: BotMascotCanvasView?

    init(_ view: BotMascotCanvasView) {
      self.view = view
    }
  }
}
