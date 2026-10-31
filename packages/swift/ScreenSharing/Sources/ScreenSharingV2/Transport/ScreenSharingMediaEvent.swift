public enum ScreenSharingMediaEvent: Sendable {
  case frame(ScreenSharingReceivedFrame)
  case frameSkipped(stream: UInt8, frame: UInt32)
  case frameAcked(ScreenSharingFrameAck)
  case frameLost(stream: UInt8, frame: UInt32)
  case ltrAcked(stream: UInt8, token: UInt64)
}
