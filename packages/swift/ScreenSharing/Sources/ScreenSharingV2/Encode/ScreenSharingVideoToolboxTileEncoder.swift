import Dispatch
import CoreVideo
import ScreenSharing
import Synchronization

public final class ScreenSharingVideoToolboxTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  public let layout: ScreenSharingV2TileLayout
  public let sourcePixelFormat = ScreenSharingV2Profile.capturePixelFormat
  let sessions: [ScreenSharingVideoToolboxTileSession]
  private let totalBitrate: Atomic<Int>
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
    totalBitrate = Atomic(configuration.bitrate)
    cutter = ScreenSharingV2TileCutter(layout: layout)
    sessions = try layout.tiles.sorted().map { [relay] tile in
      let factory = ScreenSharingVideoToolboxSessionFactory(
        width: layout.width, height: layout.rows(of: tile).count, framesPerSecond: configuration.framesPerSecond,
        bitrate: configuration.bitrate)
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

    let tiles = request.update.tiles.sorted()
    let cutNs = ScreenSharingMetrics.nowNs
    let pixels: [Int: CVPixelBuffer]
    do {
      pixels = try cutter.cut(request.pixelBuffer, tiles: tiles.filter(sessions.indices.contains))
    } catch {
      return tiles.forEach { fail($0, request, error) }
    }
    if layout.count > 1 { metrics.observe("tileCut", milliseconds: Double(ScreenSharingMetrics.nowNs - cutNs) / 1e6) }
    defer {
      metrics.observe("updateSubmit", milliseconds: Double(ScreenSharingMetrics.nowNs - cutNs) / 1e6)
    }
    let bitrateShare = totalBitrate.load(ordering: .relaxed) / max(1, tiles.count)
    DispatchQueue.concurrentPerform(iterations: tiles.count) { index in
      let tile = tiles[index]
      do {
        guard let tilePixels = pixels[tile] else { throw ScreenSharingError.invalid("No tile \(tile).") }

        share(bitrateShare, with: sessions[tile])
        try sessions[tile].encode(tilePixels, request: request)
      } catch {
        fail(tile, request, error)
      }
    }
  }

  private func share(_ bitsPerSecond: Int, with session: ScreenSharingVideoToolboxTileSession) {
    do { try session.share(bitsPerSecond) } catch { metrics.label("lastBitrateError", error.localizedDescription) }
  }

  private func fail(_ tile: Int, _ request: ScreenSharingTileEncodeRequest, _ error: any Error) {
    metrics.increment("encodeErrors")
    relay.emit(.failed(tile: tile, refresh: request.refreshes[tile], message: error.localizedDescription))
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard sessions.indices.contains(tile) else { return }

    sessions[tile].acknowledge(tokens)
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    totalBitrate.store(bitsPerSecond, ordering: .relaxed)
    metrics.label("encoderBitrate", String(bitsPerSecond))
  }

  public func stop() {
    guard !stopped.exchange(true, ordering: .relaxed) else { return }

    relay.set(nil)
    for session in sessions { session.close() }
  }

}
