import CodevisorNet
import Foundation
import ScreenSharing
import ScreenSharingBench
import ScreenSharingV2
import Synchronization

final class V2MediaTap: ScreenSharingMediaTransport, @unchecked Sendable {
  struct Key: Hashable {
    let stream: UInt8
    let frame: UInt32
  }

  struct Sent {
    let sendNs: Int64
    var queuedUs: UInt64?
    var sendingUs: UInt64?
  }

  struct Receipt {
    let key: Key
    let assemblingUs: UInt64
    let recovery: BenchMediaRecovery
  }

  let inner: ScreenSharingIrohMediaTransport
  private let sent = Mutex<[Key: Sent]>([:])
  private let receipts = Mutex<[Int64: Receipt]>([:])

  init(_ inner: ScreenSharingIrohMediaTransport) {
    self.inner = inner
  }

  var session: MediaSessionHandle { inner.session }

  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws {
    let stream = UInt8(tile.tile)
    let sendNs = ScreenSharingMetrics.nowNs
    let number = try tile.accessUnit.withUnsafeBytes { bytes in
      try inner.session.sendFrame(
        stream: stream, keyframe: tile.isKeyFrame, ltrToken: tile.ltrToken, meta: meta, data: bytes)
    }
    sent.withLock { $0[Key(stream: stream, frame: number)] = Sent(sendNs: sendNs) }
  }

  func admission() -> ScreenSharingMediaAdmission {
    inner.admission()
  }

  func nextEvent() async -> ScreenSharingMediaEvent? {
    let event = await inner.nextEvent()
    switch event {
    case .frameAcked(let ack): acked(ack)
    case .frame(let frame): received(frame)
    case .frameSkipped, .frameLost, .ltrAcked, nil: break
    }
    return event
  }

  func acknowledge(ltrToken: UInt64, stream: UInt8) {
    inner.acknowledge(ltrToken: ltrToken, stream: stream)
  }

  var roundTripUs: UInt64 { inner.roundTripUs }

  func close() {
    inner.close()
  }

  func sentFrame(_ key: Key) -> Sent? {
    sent.withLock { $0[key] }
  }

  func receipt(sourceNs: Int64) -> Receipt? {
    receipts.withLock { $0[sourceNs] }
  }

  private func acked(_ ack: ScreenSharingFrameAck) {
    sent.withLock { frames in
      let key = Key(stream: ack.stream, frame: ack.frame)
      frames[key]?.queuedUs = ack.queuedUs
      frames[key]?.sendingUs = ack.sendingUs
    }
  }

  private func received(_ frame: ScreenSharingReceivedFrame) {
    guard let meta = try? ScreenSharingV2FrameMeta(frame.meta) else { return }

    let receipt = Receipt(
      key: Key(stream: frame.stream, frame: frame.frame), assemblingUs: frame.assemblingUs,
      recovery: Self.recovery(frame.recovery))
    receipts.withLock { receipts in
      if receipts[meta.sourceTimestampNs] == nil { receipts[meta.sourceTimestampNs] = receipt }
    }
  }

  private static func recovery(_ recovery: ScreenSharingFrameRecovery) -> BenchMediaRecovery {
    switch recovery {
    case .none: .none
    case .forwardErrorCorrection: .fec
    case .retransmission: .nack
    }
  }
}
