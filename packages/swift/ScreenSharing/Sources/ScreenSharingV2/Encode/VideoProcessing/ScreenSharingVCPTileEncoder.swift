import CoreVideo
import Dispatch
import ScreenSharing
import Synchronization

public final class ScreenSharingVCPTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  public let layout: ScreenSharingV2TileLayout
  public let sourcePixelFormat = kCVPixelFormatType_32BGRA
  private static let convergingPolicy = ScreenSharingV2RefinementPolicy(
    convergedBelowBytes: ScreenSharingVCPRate.convergedRefinementBytes)
  private let bitsPerSecond: Atomic<Int>
  private let converter: ScreenSharingVCPPixelConverter
  private let cutter: ScreenSharingV2TileCutter
  private let sessions: [ScreenSharingVCPTileSession]
  private let metrics: ScreenSharingMetrics
  private let relay = ScreenSharingTileOutputRelay()
  private let preparing = DispatchQueue(label: "codevisor.screen-sharing.vcp.prepare", qos: .userInteractive)
  private let stopped = Atomic(false)

  public convenience init(configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics) throws {
    try self.init(
      configuration: configuration, layout: ScreenSharingV2Profile.tileLayout(for: configuration), metrics: metrics)
  }

  public init(
    configuration: ScreenSharingVideoConfiguration, layout: ScreenSharingV2TileLayout, metrics: ScreenSharingMetrics
  ) throws {
    self.layout = layout
    self.metrics = metrics
    bitsPerSecond = Atomic(configuration.bitrate)
    converter = try ScreenSharingVCPPixelConverter(layout: layout)
    cutter = ScreenSharingV2TileCutter(layout: layout)
    sessions = try Self.sessions(layout: layout, configuration: configuration, metrics: metrics, relay: relay)
    metrics.label("encoder", "VideoProcessing VCP HEVC 4:4:4 (Usage 42), one session per tile, acknowledged references")
    metrics.label("encoderSize", "\(layout.width)x\(layout.height)")
    metrics.label("encoderTiles", "\(layout.count) of \(layout.width)x\(layout.tileHeight)")
  }

  deinit { stop() }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    relay.set(handler)
  }

  public func prepare(_ frame: ScreenSharingVideoFrame, tiles: Set<Int>) {
    guard !stopped.load(ordering: .relaxed), !tiles.isEmpty else { return }

    preparing.async { [converter, metrics] in
      let startNs = ScreenSharingMetrics.nowNs
      guard
        (try? converter.convertTiles(frame.pixelBuffer, capture: frame.timestampNs, tiles: tiles.sorted())) != nil
      else { return }

      metrics.observe("vcpPrepare", milliseconds: Double(ScreenSharingMetrics.nowNs - startNs) / 1e6)
    }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    guard !stopped.load(ordering: .relaxed) else { throw ScreenSharingError.unavailable("Encoder stopped.") }

    let tiles = request.update.tiles.sorted().filter(sessions.indices.contains)
    let startNs = ScreenSharingMetrics.nowNs
    let pixels = try tilePixels(request, tiles: tiles)
    for tile in tiles { encode(tile, pixels: pixels[tile], request: request) }
    metrics.observe("updateSubmit", milliseconds: Double(ScreenSharingMetrics.nowNs - startNs) / 1e6)
  }

  private func tilePixels(_ request: ScreenSharingTileEncodeRequest, tiles: [Int]) throws -> [Int: CVPixelBuffer] {
    let startNs = ScreenSharingMetrics.nowNs
    let observeConvert = {
      guard !request.update.isRefinement else { return }
      self.metrics.observe("vcpConvert", milliseconds: Double(ScreenSharingMetrics.nowNs - startNs) / 1e6)
    }
    if let converted = try converter.convertTiles(request.pixelBuffer, capture: request.sourceTimestampNs, tiles: tiles)
    {
      observeConvert()
      return converted
    }
    let converted = try converter.convert(request.pixelBuffer, capture: request.sourceTimestampNs)
    observeConvert()
    let cutNs = ScreenSharingMetrics.nowNs
    let pixels = try cutter.cut(converted, tiles: tiles)
    if layout.count > 1 { metrics.observe("tileCut", milliseconds: Double(ScreenSharingMetrics.nowNs - cutNs) / 1e6) }
    return pixels
  }

  private func encode(_ tile: Int, pixels: CVPixelBuffer?, request: ScreenSharingTileEncodeRequest) {
    do {
      guard let pixels else { throw ScreenSharingError.invalid("No tile \(tile).") }

      try sessions[tile].encode(pixels, request: request)
    } catch {
      metrics.increment("encodeErrors")
      relay.emit(.failed(tile: tile, refresh: request.refreshes[tile], message: error.localizedDescription))
    }
  }

  private static func sessions(
    layout: ScreenSharingV2TileLayout, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    relay: ScreenSharingTileOutputRelay
  ) throws -> [ScreenSharingVCPTileSession] {
    let rate = ScreenSharingVCPRate(bitsPerSecond: configuration.bitrate, tiles: layout.count)
    var sessions: [ScreenSharingVCPTileSession] = []
    do {
      for tile in layout.tiles.sorted() {
        let factory = ScreenSharingVCPSessionFactory(
          width: layout.width, height: layout.rows(of: tile).count, framesPerSecond: configuration.framesPerSecond,
          rate: rate)
        sessions.append(try ScreenSharingVCPTileSession(tile: tile, factory: factory, metrics: metrics, relay: relay))
      }
      return sessions
    } catch {
      for session in sessions { session.close() }
      throw error
    }
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard sessions.indices.contains(tile) else { return }

    sessions[tile].acknowledge(tokens)
  }

  public var refinementPolicy: ScreenSharingV2RefinementPolicy {
    let rate = ScreenSharingVCPRate(bitsPerSecond: bitsPerSecond.load(ordering: .relaxed), tiles: layout.count)
    return rate.refinesNearLossless ? Self.convergingPolicy : .standard
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    self.bitsPerSecond.store(bitsPerSecond, ordering: .relaxed)
    let rate = ScreenSharingVCPRate(bitsPerSecond: bitsPerSecond, tiles: layout.count)
    for session in sessions {
      try session.setRate(rate)
    }
    metrics.label("encoderBitrate", String(rate.tileBitsPerSecond * layout.count))
  }

  public func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {
    for session in sessions { session.setNetworkFeedback(feedback) }
  }

  public func stop() {
    guard !stopped.exchange(true, ordering: .relaxed) else { return }

    for session in sessions { session.close() }
    relay.set(nil)
  }
}
