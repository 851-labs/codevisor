import CoreImage
import CoreVideo
import Foundation
import IOSurface
import ScreenSharing

protocol SimulatorFrameSink: AnyObject, Sendable {
  @MainActor func prepare(size: CGSize)
  func push(_ frame: ScreenSharingVideoFrame)
}

final class SimulatorScreenCapture: @unchecked Sendable {
  static let maximumSize = CGSize(width: 3840, height: 2160)
  private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

  private let screen: SimulatorRuntime.Screen
  private let queue = DispatchQueue(label: "codevisor.simulator.capture", qos: .userInteractive)
  private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
  private var token: UUID?
  private var viewers: [ObjectIdentifier: Viewer] = [:]
  private var pools: [PixelSize: CVPixelBufferPool] = [:]
  private var lastTimestamp: Int64 = 0
  private var pending = false
  private var resizing = false
  private(set) var outputSize: CGSize = .zero

  private struct Viewer {
    let sink: any SimulatorFrameSink
    var size: CGSize?
  }

  private struct PixelSize: Hashable {
    let width: Int
    let height: Int
    init(_ size: CGSize) { width = Int(size.width); height = Int(size.height) }
    var size: CGSize { CGSize(width: width, height: height) }
  }

  init(screen: SimulatorRuntime.Screen) {
    self.screen = screen
  }

  var size: CGSize? {
    guard let surface = screen.surface else { return nil }
    return Self.outputSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
  }

  static func outputSize(width: Int, height: Int) -> CGSize {
    let scale = min(1, maximumSize.width / CGFloat(max(1, width)), maximumSize.height / CGFloat(max(1, height)))
    func even(_ value: Int) -> CGFloat { max(64, ((CGFloat(value) * scale + 0.001) / 2).rounded(.down) * 2) }
    return CGSize(width: even(width), height: even(height))
  }

  @MainActor func start() {
    guard token == nil else { return }
    token = SimulatorRuntime.observe(
      screen, queue: queue,
      frame: { [weak self] in self?.frameArrived() },
      surfacesChanged: { [weak self] in self?.frameArrived() })
    queue.async { [weak self] in self?.frameArrived() }
  }

  @MainActor func stop() {
    if let token { SimulatorRuntime.stopObserving(screen, token: token) }
    token = nil
    queue.async { [weak self] in self?.viewers.removeAll() }
  }

  func add(_ sink: any SimulatorFrameSink) {
    queue.async { [weak self] in
      self?.viewers[ObjectIdentifier(sink)] = Viewer(sink: sink)
      self?.frameArrived()
    }
  }

  func remove(_ sink: any SimulatorFrameSink) {
    queue.async { [weak self] in _ = self?.viewers.removeValue(forKey: ObjectIdentifier(sink)) }
  }

  func request(_ size: CGSize, from base: CGSize, for sink: any SimulatorFrameSink) {
    queue.async { [weak self] in
      let id = ObjectIdentifier(sink)
      guard let self, self.outputSize == base, self.viewers[id] != nil else { return }
      self.viewers[id]?.size = size == base ? nil : size
      self.frameArrived()
    }
  }

  private func frameArrived() {
    guard !pending, !resizing, !viewers.isEmpty else { return }
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
    let size = Self.outputSize(width: width, height: height)
    if size != outputSize {
      outputSize = size
      resizing = true
      for id in viewers.keys { viewers[id]?.size = nil }
      let sinks = viewers.values.map(\.sink)
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
    let groups = Dictionary(grouping: viewers.values) { PixelSize($0.size ?? size) }
    pools = pools.filter { groups[$0.key] != nil }
    let image = CIImage(ioSurface: surface)
    let now = Int64(DispatchTime.now().uptimeNanoseconds)
    lastTimestamp = max(now, lastTimestamp + 1)
    for (pixels, members) in groups {
      guard let output = pixelBuffer(pixels) else { continue }
      let target = pixels.size
      let scaled = image.transformed(
        by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
      context.render(
        scaled, to: output, bounds: CGRect(origin: .zero, size: target), colorSpace: Self.outputColorSpace)
      let frame = ScreenSharingVideoFrame(pixelBuffer: output, timestampNs: lastTimestamp)
      for member in members { member.sink.push(frame) }
    }
  }

  private func pixelBuffer(_ size: PixelSize) -> CVPixelBuffer? {
    if pools[size] == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      var created: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
      pools[size] = created
    }
    guard let pool = pools[size] else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    return buffer
  }
}
