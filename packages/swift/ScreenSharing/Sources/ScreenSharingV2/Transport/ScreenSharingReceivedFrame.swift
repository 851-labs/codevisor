import Foundation

public struct ScreenSharingReceivedFrame: Sendable {
  public let stream: UInt8
  public let frame: UInt32
  public let isKeyFrame: Bool
  public let ltrToken: UInt64?
  public let meta: Data
  public let payload: any ScreenSharingBytes
  public let assemblingUs: UInt64
  public let recovery: ScreenSharingFrameRecovery

  public init(
    stream: UInt8, frame: UInt32, isKeyFrame: Bool, ltrToken: UInt64?, meta: Data, payload: any ScreenSharingBytes,
    assemblingUs: UInt64, recovery: ScreenSharingFrameRecovery
  ) {
    self.stream = stream
    self.frame = frame
    self.isKeyFrame = isKeyFrame
    self.ltrToken = ltrToken
    self.meta = meta
    self.payload = payload
    self.assemblingUs = assemblingUs
    self.recovery = recovery
  }
}
