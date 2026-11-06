import CoreVideo
import ScreenSharing
import Synchronization

@testable import ScreenSharingV2

final class FailingTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  enum Failure {
    case none
    case throwsOnEncode
    case failsOutputs
  }

  private let inner: any ScreenSharingTileEncoder
  private let failure = Mutex(Failure.none)
  private struct Receiver {
    var handler: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
  }

  private let output = Mutex(Receiver())

  init(_ inner: any ScreenSharingTileEncoder) {
    self.inner = inner
    inner.onOutput { [weak self] result in self?.relay(result) }
  }

  var layout: ScreenSharingV2TileLayout { inner.layout }
  var sourcePixelFormat: OSType { inner.sourcePixelFormat }
  var refinementPolicy: ScreenSharingV2RefinementPolicy { inner.refinementPolicy }

  func fail(_ next: Failure) {
    failure.withLock { $0 = next }
  }

  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    output.withLock { $0.handler = handler }
  }

  func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    if failure.withLock({ $0 }) == .throwsOnEncode { throw ScreenSharingError.unavailable("Forced failure.") }

    try inner.encode(request)
  }

  func acknowledge(_ tokens: [UInt64], tile: Int) { inner.acknowledge(tokens, tile: tile) }

  func setBitrate(_ bitsPerSecond: Int) throws { try inner.setBitrate(bitsPerSecond) }

  func stop() { inner.stop() }

  private func relay(_ result: ScreenSharingTileEncoderOutput) {
    let forwarded = failure.withLock { $0 } == .failsOutputs ? Self.failed(result) : result
    output.withLock { $0.handler }?(forwarded)
  }

  private static func failed(_ result: ScreenSharingTileEncoderOutput) -> ScreenSharingTileEncoderOutput {
    switch result {
    case .tile(let tile): .failed(tile: tile.tile, refresh: tile.refresh, message: "Forced failure.")
    case .dropped(let tile, let refresh), .failed(let tile, let refresh, _):
      .failed(tile: tile, refresh: refresh, message: "Forced failure.")
    case .unchanged(let tile, _): .failed(tile: tile, refresh: nil, message: "Forced failure.")
    }
  }
}
