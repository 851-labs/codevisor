import CoreVideo
import ScreenSharing
import ScreenSharingV2
import Synchronization

final class V2ForcedFailureEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  private static let message = "Forced VCP failure (--vcp-fail-after)"

  private let inner: any ScreenSharingTileEncoder
  private let failsAt: ContinuousClock.Instant
  private let metrics: ScreenSharingMetrics
  private struct Receiver {
    var handler: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
  }

  private let output = Mutex(Receiver())
  private let failed = Atomic(false)

  init(_ inner: any ScreenSharingTileEncoder, after delay: Duration, metrics: ScreenSharingMetrics) {
    self.inner = inner
    self.metrics = metrics
    failsAt = .now + delay
    inner.onOutput { [weak self] result in self?.relay(result) }
  }

  var layout: ScreenSharingV2TileLayout { inner.layout }
  var sourcePixelFormat: OSType { inner.sourcePixelFormat }
  var refinementPolicy: ScreenSharingV2RefinementPolicy { inner.refinementPolicy }

  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    output.withLock { $0.handler = handler }
  }

  func encode(_ request: ScreenSharingTileEncodeRequest) throws { try inner.encode(request) }

  func acknowledge(_ tokens: [UInt64], tile: Int) { inner.acknowledge(tokens, tile: tile) }

  func setBitrate(_ bitsPerSecond: Int) throws { try inner.setBitrate(bitsPerSecond) }

  func stop() { inner.stop() }

  private func relay(_ result: ScreenSharingTileEncoderOutput) {
    let forwarded = isFailing ? Self.failure(of: result) : result
    output.withLock { $0.handler }?(forwarded)
  }

  private var isFailing: Bool {
    guard ContinuousClock.now >= failsAt else { return false }
    if !failed.exchange(true, ordering: .relaxed) {
      metrics.label("forcedFailureNs", String(ScreenSharingMetrics.nowNs))
    }

    return true
  }

  private static func failure(of result: ScreenSharingTileEncoderOutput) -> ScreenSharingTileEncoderOutput {
    switch result {
    case .tile(let tile): .failed(tile: tile.tile, refresh: tile.refresh, message: message)
    case .dropped(let tile, let refresh), .failed(let tile, let refresh, _):
      .failed(tile: tile, refresh: refresh, message: message)
    case .unchanged(let tile, _): .failed(tile: tile, refresh: nil, message: message)
    case .keyframeNeeded: result
    }
  }
}
