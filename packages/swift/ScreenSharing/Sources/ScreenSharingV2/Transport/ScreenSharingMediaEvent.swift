public enum ScreenSharingMediaEvent: Sendable {
  case frame(ScreenSharingReceivedFrame)
  case frameSkipped(stream: UInt8, frame: UInt32)
  case frameAcked(ScreenSharingFrameAck)
  case frameLost(stream: UInt8, frame: UInt32)
  case ltrAcked(stream: UInt8, token: UInt64)
  case refreshRequested(stream: UInt8, keyframe: Bool)

  var stream: UInt8? {
    switch self {
    case .frame(let frame): frame.stream
    case .frameAcked(let ack): ack.stream
    case .frameSkipped(let stream, _), .frameLost(let stream, _), .ltrAcked(let stream, _),
      .refreshRequested(let stream, _):
      stream
    }
  }
}
