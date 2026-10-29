public struct ScreenSharingHostTimestamps: Codable, Equatable, Sendable {
  public let sckDisplayTimeNs: Int64
  public let captureCallbackNs: Int64
  public let encodeSubmitNs: Int64
  public let encodeOutputNs: Int64

  init(sourceTimestampNs: Int64, timing: ScreenSharingHostFrameTiming) {
    sckDisplayTimeNs = sourceTimestampNs
    captureCallbackNs = sourceTimestampNs + timing.captureUs * 1000
    encodeSubmitNs = captureCallbackNs + timing.hostQueueUs * 1000
    encodeOutputNs = encodeSubmitNs + timing.encodeUs * 1000
  }
}
