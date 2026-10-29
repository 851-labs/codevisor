package struct ScreenSharingDecodedFrameTiming: Equatable, Sendable {
  package let sourceTimestampNs: Int64
  package let host: ScreenSharingHostFrameTiming?
  package let decodeInputNs: Int64
  package let decodeSubmitNs: Int64
  package let decodedNs: Int64
  package let isKeyFrame: Bool

  package init(
    sourceTimestampNs: Int64, host: ScreenSharingHostFrameTiming?, decodeInputNs: Int64, decodeSubmitNs: Int64,
    decodedNs: Int64, isKeyFrame: Bool
  ) {
    self.sourceTimestampNs = sourceTimestampNs
    self.host = host
    self.decodeInputNs = decodeInputNs
    self.decodeSubmitNs = decodeSubmitNs
    self.decodedNs = decodedNs
    self.isKeyFrame = isKeyFrame
  }
}
