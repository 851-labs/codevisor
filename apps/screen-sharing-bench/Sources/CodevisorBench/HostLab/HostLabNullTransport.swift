import Foundation
import ScreenSharingV2
import Synchronization

final class HostLabNullTransport: ScreenSharingMediaTransport, @unchecked Sendable {
  private var events: AsyncStream<ScreenSharingMediaEvent>.Iterator
  private let continuation: AsyncStream<ScreenSharingMediaEvent>.Continuation
  private let sizes = Mutex(HostLabTileSizes())
  private static let ackDelay = DispatchTimeInterval.milliseconds(1)
  private let admitted = ScreenSharingMediaAdmission(
    admit: true, backlogBytes: 0, estimateKbps: UInt64(ScreenSharingV2Profile.bitrateCeiling / 1000),
    encoderCeilingKbps: UInt64(ScreenSharingV2Profile.bitrateCeiling / 1000), sampled: true)

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: ScreenSharingMediaEvent.self)
    events = stream.makeAsyncIterator()
    self.continuation = continuation
  }

  var passes: [HostLabTileSizes.Pass] { sizes.withLock { $0.passes } }

  @discardableResult
  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32 {
    sizes.withLock {
      $0.record(tile: tile.tile, isRefinement: tile.update.isRefinement, bytes: tile.accessUnit.count)
    }
    guard let token = tile.ltrToken else { return 0 }

    let event = ScreenSharingMediaEvent.ltrAcked(stream: UInt8(tile.tile), token: token)
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.ackDelay) { [continuation] in continuation.yield(event) }
    return 0
  }

  func admission() -> ScreenSharingMediaAdmission { admitted }

  func nextEvent() async -> ScreenSharingMediaEvent? {
    await events.next()
  }

  func acknowledge(ltrToken: UInt64, stream: UInt8) {}

  func requestRefresh(stream: UInt8, keyframe: Bool) {}

  var roundTripUs: UInt64 { 0 }

  var lossRate: Double { 0 }

  func close() { continuation.finish() }
}
