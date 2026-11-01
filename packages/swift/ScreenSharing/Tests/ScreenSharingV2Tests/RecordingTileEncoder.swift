import CodevisorTestSupport
import Foundation
import Synchronization

@testable import ScreenSharingV2

final class RecordingTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  let tileCount = 1
  let encodes = TestSignal()
  private let recorded = Mutex<[ScreenSharingTileEncodeRequest]>([])
  private let acknowledged = Mutex<[UInt64]>([])
  private let output = Mutex<(@Sendable (ScreenSharingTileEncoderOutput) -> Void)?>(nil)

  var requests: [ScreenSharingTileEncodeRequest] { recorded.withLock { $0 } }
  var acknowledgedTokens: [UInt64] { acknowledged.withLock { $0 } }

  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    output.withLock { $0 = handler }
  }

  func emit(_ result: ScreenSharingTileEncoderOutput) {
    output.withLock { $0 }?(result)
  }

  func emitTile(of request: ScreenSharingTileEncodeRequest, keyframe: Bool, token: UInt64?) {
    emit(
      .tile(
        ScreenSharingEncodedTile(
          tile: 0, sourceTimestampNs: request.sourceTimestampNs, capturedNs: request.capturedNs,
          submittedNs: request.capturedNs, encodedNs: request.capturedNs, isKeyFrame: keyframe, refresh: nil,
          ltrToken: token, accessUnit: ScreenSharingAccessUnit(Data([0, 0, 0, 2, 2, 1])))))
  }

  func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    recorded.withLock { $0.append(request) }
    encodes.signal()
  }

  func acknowledge(_ tokens: [UInt64], tile: Int) {
    acknowledged.withLock { $0 += tokens }
  }

  func setBitrate(_ bitsPerSecond: Int) throws {}

  func stop() {}
}
