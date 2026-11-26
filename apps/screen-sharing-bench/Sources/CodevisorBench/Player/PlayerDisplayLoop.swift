import AppKit
import Metal
import QuartzCore
import ScreenSharingBenchScenes

@MainActor
final class PlayerDisplayLoop: NSObject, CAMetalDisplayLinkDelegate {
  private let ticksPerSecond: Double
  private let frameRate: CAFrameRateRange

  private let renderer: BenchSceneRenderer
  private let queue: any MTLCommandQueue
  private let versions: PlayerVersionSource
  private let hashes: PlayerHashRecorder?
  private let stats = PlayerStats()
  private var cpu: ProcessUsageMeter?
  private var link: CAMetalDisplayLink?
  private var firstTarget: CFTimeInterval?
  private var shownVersion: Int?
  private var failure: (any Error)?

  init(
    renderer: BenchSceneRenderer, device: any MTLDevice, versions: PlayerVersionSource, hashes: PlayerHashRecorder?,
    refresh: Int = BenchSceneTimeline.ticksPerSecond
  ) throws {
    guard let queue = device.makeCommandQueue() else { throw BenchSceneError.metalUnavailable }

    self.renderer = renderer
    self.queue = queue
    self.versions = versions
    self.hashes = hashes
    ticksPerSecond = Double(refresh)
    frameRate = CAFrameRateRange(minimum: Float(refresh), maximum: Float(refresh), preferred: Float(refresh))
  }

  func start(layer: CAMetalLayer) {
    let link = CAMetalDisplayLink(metalLayer: layer)
    link.preferredFrameRateRange = frameRate
    link.delegate = self
    cpu = ProcessUsageMeter()
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() async throws -> PlayerMeasurement {
    link?.invalidate()
    link = nil
    let cpuPercent = cpu?.loadSinceStart()?.cpuPercent ?? 0
    await drain()
    if let failure { throw failure }

    return PlayerMeasurement(stats: stats.snapshot, cpuPercentOfOneCore: cpuPercent)
  }

  private func drain() async {
    guard let marker = queue.makeCommandBuffer() else { return }

    await withCheckedContinuation { drained in
      marker.addCompletedHandler { _ in drained.resume() }
      marker.commit()
    }
  }

  nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    nonisolated(unsafe) let update = update
    MainActor.assumeIsolated { self.handle(update) }
  }

  private func handle(_ update: CAMetalDisplayLink.Update) {
    let tick = tick(at: update.targetPresentationTimestamp)
    stats.recordUpdate(tick: tick, target: update.targetPresentationTimestamp)
    let version = versions.version(atTick: tick)
    guard version != shownVersion, failure == nil else { return }

    do {
      try present(version, on: update.drawable)
      shownVersion = version
    } catch {
      failure = error
      link?.isPaused = true
    }
  }

  private func tick(at target: CFTimeInterval) -> Int {
    let first = firstTarget ?? target
    firstTarget = first
    return Int(((target - first) * ticksPerSecond).rounded())
  }

  private func present(_ version: Int, on drawable: any CAMetalDrawable) throws {
    guard let commandBuffer = queue.makeCommandBuffer() else { throw BenchSceneError.encoderUnavailable }

    try renderer.encode(version: version, into: drawable.texture, commandBuffer: commandBuffer)
    try hashes?.capture(version: version, from: drawable.texture, commandBuffer: commandBuffer)
    let stats = stats
    drawable.addPresentedHandler { stats.recordPresented(at: $0.presentedTime) }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    stats.recordVersion()
  }
}
