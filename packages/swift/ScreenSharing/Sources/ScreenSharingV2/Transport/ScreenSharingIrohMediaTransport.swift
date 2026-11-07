import CodevisorNet
import Foundation

public final class ScreenSharingIrohMediaTransport: ScreenSharingMediaTransport, @unchecked Sendable {
  public let session: MediaSessionHandle

  public init(session: MediaSessionHandle) {
    self.session = session
  }

  public static var sessionConfig: MediaSessionConfig {
    MediaSessionConfig(
      frameIntervalUs: ScreenSharingV2Profile.frameIntervalUs, fecPercent: nil,
      initialRateKbps: ScreenSharingV2Profile.initialEstimateKbps)
  }

  @discardableResult
  public func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32 {
    try tile.accessUnit.withUnsafeBytes { bytes in
      try session.sendFrame(
        stream: UInt8(tile.tile), keyframe: tile.isKeyFrame, refresh: tile.recovers, ltrToken: tile.ltrToken,
        meta: meta, data: bytes)
    }
  }

  public func admission() -> ScreenSharingMediaAdmission {
    let admission = session.admission()
    return ScreenSharingMediaAdmission(
      admit: admission.admit, backlogBytes: admission.backlogBytes, estimateKbps: admission.estimateKbps,
      encoderCeilingKbps: admission.encoderCeilingKbps, sampled: admission.sampled)
  }

  public func nextEvent() async -> ScreenSharingMediaEvent? {
    guard let event = await session.nextEvent() else { return nil }

    return Self.event(event)
  }

  public func acknowledge(ltrToken: UInt64, stream: UInt8) {
    session.ackLtr(stream: stream, token: ltrToken)
  }

  public func requestRefresh(stream: UInt8, keyframe: Bool) {
    session.requestRefresh(stream: stream, keyframe: keyframe)
  }

  public var roundTripUs: UInt64 { session.stats().rttUs }

  public var lossRate: Double { session.stats().lossPercent / 100 }

  public func close() {
    session.close()
  }

  public func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool {
    session.sendDatagram(kind: kind == .audio ? .audio : .cursor, payload: payload)
  }

  private static func event(_ event: MediaEvent) -> ScreenSharingMediaEvent {
    switch event {
    case .frame(
      let stream, let frame, let keyframe, _, let ltrToken, let meta, let data, let assemblingUs, let recovery):
      .frame(
        ScreenSharingReceivedFrame(
          stream: stream, frame: frame, isKeyFrame: keyframe, ltrToken: ltrToken, meta: meta,
          payload: ScreenSharingMediaBytes(data), assemblingUs: assemblingUs, recovery: Self.recovery(recovery)))
    case .frameSkipped(let stream, let frame): .frameSkipped(stream: stream, frame: frame)
    case .frameAcked(let stream, let frame, let queuedUs, let sendingUs, let ackedAfterUs, _):
      .frameAcked(
        ScreenSharingFrameAck(
          stream: stream, frame: frame, queuedUs: queuedUs, sendingUs: sendingUs, ackedAfterUs: ackedAfterUs))
    case .frameLost(let stream, let frame): .frameLost(stream: stream, frame: frame)
    case .ltrAcked(let stream, let token): .ltrAcked(stream: stream, token: token)
    case .refreshRequested(let stream, let keyframe): .refreshRequested(stream: stream, keyframe: keyframe)
    case .datagram(let kind, let payload): .datagram(kind == .audio ? .audio : .cursor, payload)
    }
  }

  private static func recovery(_ recovery: MediaRecovery) -> ScreenSharingFrameRecovery {
    switch recovery {
    case .none: .none
    case .fec: .forwardErrorCorrection
    case .nack: .retransmission
    }
  }
}
