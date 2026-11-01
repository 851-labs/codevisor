public struct ScreenSharingFrameAck: Equatable, Sendable {
  public let stream: UInt8
  public let frame: UInt32
  public let queuedUs: UInt64
  public let sendingUs: UInt64
  public let ackedAfterUs: UInt64

  public init(stream: UInt8, frame: UInt32, queuedUs: UInt64, sendingUs: UInt64, ackedAfterUs: UInt64) {
    self.stream = stream
    self.frame = frame
    self.queuedUs = queuedUs
    self.sendingUs = sendingUs
    self.ackedAfterUs = ackedAfterUs
  }
}
