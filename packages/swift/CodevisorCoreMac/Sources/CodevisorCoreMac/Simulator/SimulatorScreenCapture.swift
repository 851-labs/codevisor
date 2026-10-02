import CoreImage
import CoreVideo
import Foundation
import IOSurface
import ScreenSharing

/// Receives the turned, scaled frames of one simulator screen.
protocol SimulatorFrameSink: AnyObject, Sendable {
  /// Called on the main actor before frames of a new size arrive.
  @MainActor func prepare(size: CGSize)
  /// Called on the capture queue.
  func push(_ frame: ScreenSharingVideoFrame)
}

/// One simulator screen's frames: copied out of the live framebuffer as the simulator draws,
/// turned upright for how the device is held, scaled to what the encoder takes, and handed to
/// every viewer's sink.
final class SimulatorScreenCapture: @unchecked Sendable {
  /// The encoder's limits (ScreenSharingVideoConfiguration).
  static let maximumSize = CGSize(width: 3840, height: 2160)
  private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

  private let screen: SimulatorRuntime.Screen
  private let queue = DispatchQueue(label: "codevisor.simulator.capture", qos: .userInteractive)
  private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
  private var token: UUID?
  // Capture-queue state.
  private var sinks: [ObjectIdentifier: any SimulatorFrameSink] = [:]
  private var pool: CVPixelBufferPool?
  private var poolSize: CGSize = .zero
  private var lastTimestamp: Int64 = 0
  private var pending = false
  /// A new size waits for every sink's encoder to take it; frames meanwhile are dropped.
  private var resizing = false
  /// Clockwise quarter turns applied to the framebuffer (screen mounting plus how it's held).
  private var turns = 0
  private(set) var outputSize: CGSize = .zero

  init(screen: SimulatorRuntime.Screen) {
    self.screen = screen
  }

  /// The size frames will have for `turns`, from the framebuffer's current size.
  func size(forTurns turns: Int) -> CGSize? {
    guard let surface = screen.surface else { return nil }
    return Self.outputSize(
      width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), turns: turns)
  }

  static func outputSize(width: Int, height: Int, turns: Int) -> CGSize {
    let turned = turns % 2 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    let scale = min(1, maximumSize.width / max(1, turned.width), maximumSize.height / max(1, turned.height))
    // A hair of slack so a side scaled exactly to a limit isn't floored below it.
    func even(_ value: CGFloat) -> CGFloat { max(64, ((value * scale + 0.001) / 2).rounded(.down) * 2) }
    return CGSize(width: even(turned.width), height: even(turned.height))
  }

  @MainActor func start() {
    guard token == nil else { return }
    token = SimulatorRuntime.observe(
      screen, queue: queue,
      frame: { [weak self] in self?.frameArrived() },
      surfacesChanged: { [weak self] in self?.frameArrived() })
    // An idle screen may not draw for a while; send what it shows now.
    queue.async { [weak self] in self?.frameArrived() }
  }

  @MainActor func stop() {
    if let token { SimulatorRuntime.stopObserving(screen, token: token) }
    token = nil
    queue.async { [weak self] in self?.sinks.removeAll() }
  }

  func setTurns(_ turns: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      self.turns = ((turns % 4) + 4) % 4
      self.frameArrived()
    }
  }

  func add(_ sink: any SimulatorFrameSink) {
    queue.async { [weak self] in
      self?.sinks[ObjectIdentifier(sink)] = sink
      self?.frameArrived()
    }
  }

  func remove(_ sink: any SimulatorFrameSink) {
    queue.async { [weak self] in _ = self?.sinks.removeValue(forKey: ObjectIdentifier(sink)) }
  }

  /// Coalesces bursts: one conversion in flight, the next one reads the latest framebuffer.
  private func frameArrived() {
    guard !pending, !resizing, !sinks.isEmpty else { return }
    pending = true
    queue.async { [weak self] in
      guard let self else { return }
      self.pending = false
      self.convert()
    }
  }

  private func convert() {
    guard let surface = screen.surface else { return }
    let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
    let size = Self.outputSize(width: width, height: height, turns: turns)
    if size != outputSize {
      // Each encoder must learn the new size before frames of that size reach it.
      outputSize = size
      resizing = true
      let sinks = Array(sinks.values)
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { for sink in sinks { sink.prepare(size: size) } }
        guard let self else { return }
        self.queue.async {
          self.resizing = false
          self.frameArrived()
        }
      }
      return
    }
    guard let output = pixelBuffer(size: size) else { return }
    var image = CIImage(ioSurface: surface)
    // Core Image is y-up: a clockwise turn on screen is a negative rotation here.
    image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    image = image.transformed(
      by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
    // Core Image works in linear light: name the output's space, or it gets linear values and the
    // screen looks washed out. The encoder and viewer treat frames as sRGB.
    context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.outputColorSpace)
    let now = Int64(DispatchTime.now().uptimeNanoseconds)
    lastTimestamp = max(now, lastTimestamp + 1)
    let frame = ScreenSharingVideoFrame(pixelBuffer: output, timestampNs: lastTimestamp)
    for sink in sinks.values { sink.push(frame) }
  }

  private func pixelBuffer(size: CGSize) -> CVPixelBuffer? {
    if pool == nil || poolSize != size {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      var created: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
      pool = created
      poolSize = size
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    return buffer
  }
}
