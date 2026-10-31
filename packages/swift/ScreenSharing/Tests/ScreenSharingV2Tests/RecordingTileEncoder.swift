import CodevisorTestSupport
import Synchronization

@testable import ScreenSharingV2

final class RecordingTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  let tileCount = 1
  let encodes = TestSignal()
  private let recorded = Mutex<[ScreenSharingTileEncodeRequest]>([])
  private let acknowledged = Mutex<[UInt64]>([])

  var framesInFlight: Int { 0 }
  var requests: [ScreenSharingTileEncodeRequest] { recorded.withLock { $0 } }
  var acknowledgedTokens: [UInt64] { acknowledged.withLock { $0 } }

  func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {}

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
