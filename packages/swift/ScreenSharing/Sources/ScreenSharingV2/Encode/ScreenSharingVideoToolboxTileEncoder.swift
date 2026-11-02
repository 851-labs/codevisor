import CoreVideo
import ScreenSharing
import Synchronization

public final class ScreenSharingVideoToolboxTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  public let layout: ScreenSharingV2TileLayout
  private let sessions: [ScreenSharingVideoToolboxTileSession]
  private let cutter: ScreenSharingV2TileCutter
  private let metrics: ScreenSharingMetrics
  private let relay = ScreenSharingTileOutputRelay()
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
    cutter = ScreenSharingV2TileCutter(layout: layout)
    sessions = try layout.tiles.sorted().map { [relay] tile in
      let factory = ScreenSharingVideoToolboxSessionFactory(
        width: layout.width, height: layout.rows(of: tile).count, framesPerSecond: configuration.framesPerSecond,
        bitrate: configuration.bitrate / layout.count)
      return try ScreenSharingVideoToolboxTileSession(tile: tile, factory: factory, metrics: metrics, relay: relay)
    }
    metrics.label("encoder", "VideoToolbox HEVC Main, low-latency rate control, LTR, no periodic keyframe")
    metrics.label("encoderSize", "\(layout.width)x\(layout.height)")
    metrics.label("encoderTiles", "\(layout.count) of \(layout.width)x\(layout.tileHeight)")
  }

  deinit { stop() }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    relay.set(handler)
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    guard !stopped.load(ordering: .relaxed) else { throw ScreenSharingError.unavailable("Encoder stopped.") }

    for tile in request.update.tiles.sorted() {
      do {
        try encode(tile: tile, request)
      } catch {
        metrics.increment("encodeErrors")
        relay.emit(.failed(tile: tile, refresh: request.refreshes[tile], message: error.localizedDescription))
      }
    }
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard sessions.indices.contains(tile) else { return }

    sessions[tile].acknowledge(tokens)
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    for session in sessions { try session.setBitrate(bitsPerSecond / layout.count) }
    metrics.label("encoderBitrate", String(bitsPerSecond))
  }

  public func stop() {
    guard !stopped.exchange(true, ordering: .relaxed) else { return }

    relay.set(nil)
    for session in sessions { session.close() }
  }

  private func encode(tile: Int, _ request: ScreenSharingTileEncodeRequest) throws {
    guard sessions.indices.contains(tile) else { throw ScreenSharingError.invalid("No tile \(tile).") }

    let cutNs = ScreenSharingMetrics.nowNs
    let pixels = try cutter.cut(request.pixelBuffer, tile: tile)
    if layout.count > 1 { metrics.observe("tileCut", milliseconds: Double(ScreenSharingMetrics.nowNs - cutNs) / 1e6) }
    try sessions[tile].encode(pixels, request: request)
  }
}
