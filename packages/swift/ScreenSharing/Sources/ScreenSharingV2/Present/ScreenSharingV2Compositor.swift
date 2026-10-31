import Foundation
@preconcurrency import Metal
import QuartzCore
import ScreenSharing
import Synchronization

final class ScreenSharingV2Compositor: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
  private struct State {
    var selection = ScreenSharingV2FrameSelection()
    var refresh = ScreenSharingV2RefreshTracker()
  }

  private static let clearColor = MTLClearColor(red: 0.025, green: 0.025, blue: 0.025, alpha: 1)

  private let layer: CAMetalLayer
  private let mailbox: ScreenSharingFrameMailbox
  private let metrics: ScreenSharingMetrics
  private let encoder: ScreenSharingMetalEncoder
  private let state = Mutex(State())
  private let loopLock = NSLock()
  private var link: CAMetalDisplayLink?
  private var runLoop: CFRunLoop?
  private var stopped = false

  init(layer: CAMetalLayer, mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw ScreenSharingError.unavailable("Metal is unavailable.")
    }

    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.isOpaque = true
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: ScreenSharingMetalView.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines)
    self.layer = layer
    self.mailbox = mailbox
    self.metrics = metrics
    super.init()
    metrics.label("presentation", "CAMetalDisplayLink, frame latency 1, latest frame wins")
  }

  func start(framesPerSecond: Float) {
    let thread = Thread { [self] in run(framesPerSecond: framesPerSecond) }
    thread.name = "Screen sharing v2 compositor"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() {
    state.withLock { $0.selection.clear() }
    let (link, runLoop) = loopLock.withLock {
      defer { self.link = nil; self.runLoop = nil; stopped = true }
      return (self.link, self.runLoop)
    }
    link?.invalidate()
    if let runLoop { CFRunLoopStop(runLoop) }
  }

  func setNeedsRedraw() {
    state.withLock { $0.selection.redraw() }
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    observeRefresh(update)
    guard let (frame, isNew) = state.withLock({ $0.selection.select(from: mailbox) }) else { return }

    render(frame, isNew: isNew, into: update.drawable)
  }

  private func run(framesPerSecond: Float) {
    let link = CAMetalDisplayLink(metalLayer: layer)
    link.delegate = self
    link.preferredFrameLatency = 1
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: framesPerSecond, maximum: framesPerSecond, preferred: framesPerSecond)
    let started = loopLock.withLock {
      guard !stopped else { return false }

      self.link = link
      runLoop = CFRunLoopGetCurrent()
      return true
    }
    guard started else { return }

    link.add(to: .current, forMode: .default)
    RunLoop.current.run()
  }

  private func observeRefresh(_ update: CAMetalDisplayLink.Update) {
    let targetNs = ScreenSharingFramePresentation.nanoseconds(update.targetPresentationTimestamp)
    guard let periodNs = state.withLock({ $0.refresh.period(atTargetNs: targetNs) }) else { return }

    metrics.timeline.observeRefresh(targetNs: targetNs, periodNs: periodNs)
  }

  private func render(_ frame: ScreenSharingVideoFrame, isNew: Bool, into drawable: any CAMetalDrawable) {
    guard let textures = encoder.textures(for: frame),
      let encoded = encoder.encode(textures, into: Self.pass(drawable), target: drawable.texture)
    else { return renderDropped() }

    ScreenSharingV2Submission(buffer: encoded.buffer, drawable: drawable, retained: encoded.retained)
      .commit(frame, isNew: isNew, metrics: metrics)
  }

  private func renderDropped() {
    metrics.increment("renderDrops")
  }

  private static func pass(_ drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = clearColor
    return pass
  }
}
