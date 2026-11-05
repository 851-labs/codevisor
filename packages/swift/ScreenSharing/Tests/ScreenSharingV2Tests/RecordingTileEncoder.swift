import CodevisorTestSupport
import Foundation
import ScreenSharing
import Synchronization

@testable import ScreenSharingV2

final class RecordingTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  let layout: ScreenSharingV2TileLayout
  let sourcePixelFormat = ScreenSharingV2Profile.capturePixelFormat
  let refinementPolicy: ScreenSharingV2RefinementPolicy
  let encodes = TestSignal()
  let attached = TestSignal()
  private let recorded = Mutex<[ScreenSharingTileEncodeRequest]>([])
  private let preparations = Mutex<[(timestampNs: Int64, tiles: Set<Int>)]>([])
  private let acknowledged = Mutex<[UInt64]>([])
  private let network = Mutex<[ScreenSharingTileNetworkFeedback]>([])
  private let output = Mutex<(@Sendable (ScreenSharingTileEncoderOutput) -> Void)?>(nil)

  init(
    layout: ScreenSharingV2TileLayout = ScreenSharingV2TileLayout(width: 640, height: 360, count: 1),
    refinementPolicy: ScreenSharingV2RefinementPolicy = .standard
  ) {
    self.layout = layout
    self.refinementPolicy = refinementPolicy
  }

  var requests: [ScreenSharingTileEncodeRequest] { recorded.withLock { $0 } }
  var prepared: [(timestampNs: Int64, tiles: Set<Int>)] { preparations.withLock { $0 } }
  var acknowledgedTokens: [UInt64] { acknowledged.withLock { $0 } }
  var networkFeedback: [ScreenSharingTileNetworkFeedback] { network.withLock { $0 } }

  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    output.withLock { $0 = handler }
    attached.signal()
  }

  func emit(_ result: ScreenSharingTileEncoderOutput) {
    output.withLock { $0 }?(result)
  }

  func emitTiles(of request: ScreenSharingTileEncodeRequest) {
    for tile in request.update.tiles.sorted() { emitTile(of: request, tile: tile, keyframe: false, token: nil) }
  }

  func emitTile(
    of request: ScreenSharingTileEncodeRequest, tile: Int = 0, keyframe: Bool, token: UInt64?,
    refresh: ScreenSharingTileRefresh? = nil
  ) {
    emit(
      .tile(
        ScreenSharingEncodedTile(
          tile: tile, update: request.update, sourceTimestampNs: request.sourceTimestampNs,
          capturedNs: request.capturedNs,
          submittedNs: request.capturedNs, encodedNs: request.capturedNs, isKeyFrame: keyframe, refresh: refresh,
          ltrToken: token, accessUnit: ScreenSharingAccessUnit(Data([0, 0, 0, 2, 2, 1])))))
  }

  func prepare(_ frame: ScreenSharingVideoFrame, tiles: Set<Int>) {
    preparations.withLock { $0.append((frame.timestampNs, tiles)) }
  }

  func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    recorded.withLock { $0.append(request) }
    encodes.signal()
  }

  func acknowledge(_ tokens: [UInt64], tile: Int) {
    acknowledged.withLock { $0 += tokens }
  }

  func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {
    network.withLock { $0.append(feedback) }
  }

  func setBitrate(_ bitsPerSecond: Int) throws {}

  func stop() {}
}
